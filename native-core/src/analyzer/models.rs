use std::sync::{Arc, Mutex, OnceLock};
use std::cell::Cell;

use rten::Model;
use rten_tensor::prelude::*;
use sha2::{Digest, Sha256};

static BEAT: Mutex<Option<Model>> = Mutex::new(None);
static VOCAL: Mutex<Option<Model>> = Mutex::new(None);
/// A digest of the two graphs this process actually loaded. The analysis cache
/// keys on it, so a model change cannot reuse an Analysis made by the old one.
static IDENTITY: Mutex<String> = Mutex::new(String::new());
static CONFIGURED: Mutex<(String, String)> = Mutex::new((String::new(), String::new()));

thread_local! {
    static INFERENCE_THREADS: Cell<usize> = const { Cell::new(2) };
}

/// Per-plan budget, restored on scope exit (including panics). Avoid changing
/// process-wide runtime state when two engines plan concurrently.
pub(crate) struct InferenceBudget {
    previous: usize,
    _thread_bound: std::marker::PhantomData<std::rc::Rc<()>>,
}
impl InferenceBudget {
    pub(crate) fn new(threads: usize) -> Self {
        let previous = INFERENCE_THREADS.with(|value| value.replace(threads));
        Self { previous, _thread_bound: std::marker::PhantomData }
    }
}
impl Drop for InferenceBudget {
    fn drop(&mut self) { INFERENCE_THREADS.with(|value| value.set(self.previous)); }
}

pub(super) fn run_options() -> rten::RunOptions {
    static ONE: OnceLock<Arc<rten::ThreadPool>> = OnceLock::new();
    static TWO: OnceLock<Arc<rten::ThreadPool>> = OnceLock::new();
    static FOUR: OnceLock<Arc<rten::ThreadPool>> = OnceLock::new();
    let requested = INFERENCE_THREADS.with(|value| value.get());
    let (slot, threads) = match requested { 1 => (&ONE, 1), 4 => (&FOUR, 4), _ => (&TWO, 2) };
    let pool = slot.get_or_init(|| {
        let available = std::thread::available_parallelism().map_or(1, |n| n.get());
        Arc::new(rten::ThreadPool::with_num_threads(threads.min(available)))
    });
    rten::RunOptions::default().with_thread_pool(Some(pool.clone()))
}

/// Load ONNX graphs from paths the Swift model store resolved (downloaded from
/// the project's GitHub releases). Empty paths unload that model. Returns
/// whether the beat tracker is ready (vocals are optional — Automix still
/// beat-matches without a mask).
pub fn configure(beat_path: &str, vocal_path: &str) -> bool {
    // Configuration is serialized, including identity publication. Unchanged
    // graphs stay loaded when only the other model/tier changed.
    let mut configured = CONFIGURED.lock().unwrap();
    let beat_identity = digest(beat_path);
    let vocal_identity = digest(vocal_path);
    {
        let mut slot = BEAT.lock().unwrap();
        if configured.0 != beat_identity || (slot.is_none() && !beat_path.is_empty()) {
            *slot = if beat_path.is_empty() {
                None
            } else {
                match Model::load_file(beat_path) {
                    Ok(model) => {
                        log::info!("automix: loaded beat model from {beat_path}");
                        Some(model)
                    }
                    Err(err) => {
                        log::warn!("automix: beat model failed to load ({err}); energy fallback");
                        None
                    }
                }
            };
        }
    }
    {
        let mut slot = VOCAL.lock().unwrap();
        if configured.1 != vocal_identity || (slot.is_none() && !vocal_path.is_empty()) {
            *slot = if vocal_path.is_empty() {
                None
            } else {
                match Model::load_file(vocal_path) {
                    Ok(model) => {
                        log::info!("automix: loaded vocal model from {vocal_path}");
                        Some(model)
                    }
                    Err(err) => {
                        log::warn!("automix: vocal model failed to load ({err}); no mask");
                        None
                    }
                }
            };
        }
    }
    let identity = format!(
        "beat={};vocal={}",
        beat_identity,
        vocal_identity
    );
    *IDENTITY.lock().unwrap() = identity;
    *configured = (beat_identity, vocal_identity);
    analyzer_ready()
}

/// The digest of the two graphs the caller asked for (not whether they loaded):
/// a path that failed to load is still a different model set from another path,
/// and the analysis cache should not cross them.
fn digest(path: &str) -> String {
    if path.is_empty() {
        return "none".into();
    }
    match std::fs::File::open(path) {
        Ok(mut file) => {
            use std::io::Read;
            let mut hasher = Sha256::new();
            let mut bytes = [0u8; 64 * 1024];
            loop {
                let Ok(count) = file.read(&mut bytes) else { return "missing".into() };
                if count == 0 { break; }
                hasher.update(&bytes[..count]);
            }
            format!("{:x}", hasher.finalize())
        }
        Err(_) => "missing".into(),
    }
}

/// The model set the current analyses were made with, for the disk cache key.
pub(crate) fn analysis_identity() -> String {
    IDENTITY.lock().unwrap().clone()
}

pub fn analyzer_ready() -> bool {
    BEAT.lock().unwrap().is_some()
}

pub fn vocal_ready() -> bool {
    VOCAL.lock().unwrap().is_some()
}

pub fn with_beat<T>(f: impl FnOnce(&Model) -> T) -> Option<T> {
    let slot = BEAT.lock().unwrap();
    slot.as_ref().map(f)
}

pub fn with_vocal<T>(f: impl FnOnce(&Model) -> T) -> Option<T> {
    let slot = VOCAL.lock().unwrap();
    slot.as_ref().map(f)
}

/// Flatten an rten output tensor of unknown rank into a contiguous f32 buffer.
pub fn flatten_f32(value: &rten::Value) -> Option<Vec<f32>> {
    value.as_tensor_view::<f32>().map(|view| view.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn per_plan_budget_is_scoped_and_reuses_bounded_pools() {
        let balanced = run_options().thread_pool.unwrap();
        {
            let _scope = InferenceBudget::new(1);
            let first = run_options().thread_pool.unwrap();
            let second = run_options().thread_pool.unwrap();
            assert!(Arc::ptr_eq(&first, &second));
            assert!(!Arc::ptr_eq(&first, &balanced));
            assert_eq!(INFERENCE_THREADS.with(Cell::get), 1);
        }
        assert_eq!(INFERENCE_THREADS.with(Cell::get), 2);
        assert!(Arc::ptr_eq(&balanced, &run_options().thread_pool.unwrap()));
        let _ = std::panic::catch_unwind(|| {
            let _scope = InferenceBudget::new(4);
            assert_eq!(INFERENCE_THREADS.with(Cell::get), 4);
            panic!("exercise scoped restoration");
        });
        assert_eq!(INFERENCE_THREADS.with(Cell::get), 2);
    }

    #[test]
    fn load_beat_model_from_dev_cache() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/fixtures/models/beat_this.onnx"
        );
        if !std::path::Path::new(path).is_file() {
            eprintln!("skip: {path} not present (run scripts/fetch-automix-models.sh)");
            return;
        }
        let model = Model::load_file(path).expect("beat model should load");
        assert!(!model.input_ids().is_empty());
        assert!(
            model.output_ids().len() >= 2,
            "Beat This! has beat + downbeat heads, got {}",
            model.output_ids().len()
        );
        eprintln!(
            "beat inputs={} outputs={} params={}",
            model.input_ids().len(),
            model.output_ids().len(),
            model.total_params()
        );
        for (i, id) in model.input_ids().iter().enumerate() {
            let info = model.node_info(*id).unwrap();
            eprintln!("  in[{i}] {:?} {:?}", info.name(), info.shape());
        }
        for (i, id) in model.output_ids().iter().enumerate() {
            let info = model.node_info(*id).unwrap();
            eprintln!("  out[{i}] {:?} {:?}", info.name(), info.shape());
        }
        // One dummy chunk so a missing op fails here instead of at Automix time.
        let frames = 64usize;
        let chunk = vec![0.0f32; frames * 128];
        let tensor = rten_tensor::NdTensor::from_data([1, frames, 128], chunk);
        let outputs = model
            .run(
                vec![(*model.input_ids().first().unwrap(), tensor.into())],
                model.output_ids(),
                None,
            )
            .expect("beat dummy infer");
        assert!(flatten_f32(&outputs[0]).map(|v| v.len()).unwrap_or(0) >= frames);
    }

    #[test]
    fn load_vocal_model_from_dev_cache() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/fixtures/models/vocals_umxhq_int8.onnx"
        );
        if !std::path::Path::new(path).is_file() {
            eprintln!("skip: {path} not present (run scripts/fetch-automix-models.sh)");
            return;
        }
        match Model::load_file(path) {
            Ok(model) => {
                eprintln!(
                    "vocal inputs={} outputs={} params={}",
                    model.input_ids().len(),
                    model.output_ids().len(),
                    model.total_params()
                );
                for (i, id) in model.input_ids().iter().enumerate() {
                    let info = model.node_info(*id).unwrap();
                    eprintln!("  in[{i}] {:?} {:?}", info.name(), info.shape());
                }
            }
            Err(err) => {
                eprintln!("vocal model did not load ({err}); Automix continues without a mask");
            }
        }
    }
}
