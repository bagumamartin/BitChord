// MLModel runner, latency median and MLComputePlan placement report.
// usage: mlcli <model.mlpackage> <CPU_ONLY|CPU_AND_GPU|CPU_AND_NE|ALL> <inName> <d0,d1,...> [--plan]
import Foundation
import CoreML

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else { print("usage: mlcli model.mlpackage CU inName dims [--plan]"); exit(1) }
        let modelURL = URL(fileURLWithPath: args[1])
        let cuName = args[2]
        let inName = args[3]
        let dims = args[4].split(separator: ",").map { Int($0)! }
        let wantPlan = args.contains("--plan")

        let compiled = try await MLModel.compileModel(at: modelURL)
        var config = MLModelConfiguration()
        switch cuName {
        case "CPU_ONLY": config.computeUnits = .cpuOnly
        case "CPU_AND_GPU": config.computeUnits = .cpuAndGPU
        case "CPU_AND_NE": config.computeUnits = .cpuAndNeuralEngine
        default: config.computeUnits = .all
        }
        let model = try MLModel(contentsOf: compiled, configuration: config)

        // deterministic pseudo-random input, same generator for every compute unit
        let count = dims.reduce(1, *)
        var arr = [Float](repeating: 0, count: count)
        var seed: UInt64 = 12345
        for i in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            arr[i] = Float(Double(seed >> 11) / Double(1 << 53)) * 2.0
        }
        let desc = model.modelDescription.inputDescriptionsByName[inName]!
        let constraint = desc.multiArrayConstraint!
        let shape = dims.map { NSNumber(value: $0) }
        let input = try MLMultiArray(shape: shape, dataType: constraint.dataType)
        print("INPUT dataType=" + String(describing: constraint.dataType.rawValue))
        if constraint.dataType == .float16 {
            let dst = input.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count { dst[i] = Float16(arr[i]) }
        } else if constraint.dataType == .double {
            let dst = input.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { dst[i] = Double(arr[i]) }
        } else {
            let dst = input.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { dst[i] = arr[i] }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: input)])

        _ = try await model.prediction(from: provider)  // warm-up
        let iters = Int(ProcessInfo.processInfo.environment["ITERS"] ?? "25") ?? 25
        var times: [Double] = []
        for _ in 0..<iters {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try await model.prediction(from: provider)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        times.sort()
        let outputs = model.modelDescription.outputDescriptionsByName.keys.joined(separator: ",")
        print(String(format: "RESULT cu=%@ median_ms=%.3f p10_ms=%.3f min_ms=%.3f outputs=%@",
                     cuName, times[times.count/2], times[times.count/10], times[0], outputs))

        if wantPlan {
            let planConfig = MLModelConfiguration()
            switch cuName {
            case "CPU_ONLY": planConfig.computeUnits = .cpuOnly
            case "CPU_AND_GPU": planConfig.computeUnits = .cpuAndGPU
            case "CPU_AND_NE": planConfig.computeUnits = .cpuAndNeuralEngine
            default: planConfig.computeUnits = .all
            }
            let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: planConfig)
            let structure = try await plan.modelStructure
            guard case let .program(program) = structure else { print("PLAN no program"); return }
            var counts: [String: Int] = [:]
            var agg: [String: Int] = [:]
            var total = 0
            var list: [String] = []
            func deviceName(_ d: MLComputePlan.DeviceUsage?) -> String {
                guard let d = d else { return "unassigned" }
                switch d.preferred {
                case .cpu: return "CPU"
                case .gpu: return "GPU"
                case .neuralEngine: return "ANE"
                @unknown default: return "other"
                }
            }
            func visit(_ block: MLModelStructure.Program.Block, _ depth: Int) {
                for op in block.operations {
                    total += 1
                    let dev = deviceName(plan.deviceUsage(for: op))
                    counts[dev, default: 0] += 1
                    agg["\(dev) \(op.operatorName)", default: 0] += 1
                    if list.count < 30 { list.append("\(dev) \(op.operatorName)") }
                    for b in op.blocks { visit(b, depth + 1) }
                }
            }
            guard let mainFn = program.functions["main"] ?? program.functions.values.first else { print("PLAN no main"); return }
            visit(mainFn.block, 0)
            print("PLAN total_ops=\(total) " + counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
            for l in list { print("PLANOP \(l)") }
            for (k, v) in agg.sorted(by: { $0.key < $1.key }) { print("PLANAGG \(v) \(k)") }
        }
    }
}
