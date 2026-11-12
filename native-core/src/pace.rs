//! Duty-cycle pacing for background analysis.
//!
//! A transition plan, the Music Understanding decode and the lyrics feed are
//! background work: their result is wanted minutes before it is used. Run flat
//! out, each held a whole core for seconds, and beside the interface and the
//! mixer that put the app past 100% in Activity Monitor at every track change.
//! Paced, the same work runs at a fraction of a core and finishes a little
//! later. Nothing it computes changes; only when it rests.
//!
//! Pacing is per thread and only where an analysis entry point arms it, so the
//! audio render thread, which decodes through the same code, never rests here.
//! Work the armed thread waits on elsewhere (a model run on the inference pool,
//! a Neural Engine call) counts too, because the budget is wall time.

use std::cell::Cell;
use std::time::{Duration, Instant};

/// Work between checks before a rest is due. Short enough that a sampler
/// averaging over a second sees the duty cycle, not a burst.
const SLICE: Duration = Duration::from_millis(40);
/// One indivisible step (a model window) can run long; its rest is capped so
/// pacing never stalls an analysis for a noticeable stretch.
const LONGEST_REST: Duration = Duration::from_millis(400);

/// The share of a core background analysis outside a plan may use.
pub(crate) const BACKGROUND_DUTY: f64 = 0.6;

thread_local! {
    /// (duty, start of the current work slice) while armed on this thread.
    static STATE: Cell<Option<(f64, Instant)>> = const { Cell::new(None) };
}

/// Arms pacing on the calling thread until dropped. `None` leaves the thread
/// unpaced (the Performance tier). Nesting restores the outer setting.
pub(crate) struct Paced {
    previous: Option<(f64, Instant)>,
    _thread_bound: std::marker::PhantomData<std::rc::Rc<()>>,
}

impl Paced {
    pub(crate) fn arm(duty: Option<f64>) -> Self {
        let next = duty
            .filter(|d| d.is_finite() && *d > 0.0 && *d < 1.0)
            .map(|d| (d, Instant::now()));
        let previous = STATE.with(|state| state.replace(next));
        Self { previous, _thread_bound: std::marker::PhantomData }
    }
}

impl Drop for Paced {
    fn drop(&mut self) {
        STATE.with(|state| state.set(self.previous));
    }
}

/// Called from hot loops. Unarmed it is one thread-local read; armed, once a
/// slice of work has passed, it sleeps long enough to hold the duty cycle.
#[inline]
pub(crate) fn tick() {
    STATE.with(|state| {
        let Some((duty, start)) = state.get() else { return };
        let worked = start.elapsed();
        if worked < SLICE {
            return;
        }
        let rest = worked.mul_f64((1.0 - duty) / duty).min(LONGEST_REST);
        std::thread::sleep(rest);
        state.set(Some((duty, Instant::now())));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unarmed_threads_never_rest() {
        let start = Instant::now();
        for _ in 0..100_000 {
            tick();
        }
        assert!(start.elapsed() < Duration::from_millis(50));
    }

    #[test]
    fn armed_work_rests_to_its_duty_and_disarms_on_drop() {
        let busy = |until: Instant| while Instant::now() < until {};
        {
            let _paced = Paced::arm(Some(0.5));
            let start = Instant::now();
            let mut worked = Duration::ZERO;
            while worked < Duration::from_millis(200) {
                let step = Instant::now();
                busy(step + Duration::from_millis(5));
                worked += step.elapsed();
                tick();
            }
            let wall = start.elapsed();
            // Half duty: about as long resting as working.
            assert!(wall >= Duration::from_millis(330), "{wall:?}");
        }
        assert!(STATE.with(|s| s.get()).is_none());
    }

    #[test]
    fn performance_tier_is_unpaced() {
        let _paced = Paced::arm(None);
        assert!(STATE.with(|s| s.get()).is_none());
    }
}
