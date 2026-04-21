use anyhow::Result;
use time::{OffsetDateTime, macros::format_description};
use tracing_subscriber::EnvFilter;
use tracing_tree::HierarchicalLayer;
use tracing_tree::time::{FormatTime, Uptime};

#[derive(Debug, Clone, Copy, Default)]
struct LocalTimeMillis;

impl FormatTime for LocalTimeMillis {
    fn format_time(&self, w: &mut impl std::fmt::Write) -> std::fmt::Result {
        let now = OffsetDateTime::now_local().unwrap_or_else(|_| OffsetDateTime::now_utc());
        let format = format_description!(
            "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:3]"
        );
        let timestamp = now.format(&format).map_err(|_| std::fmt::Error)?;

        write!(w, "{timestamp}")
    }

    fn style_timestamp(
        &self,
        ansi: bool,
        elapsed: std::time::Duration,
        w: &mut impl std::fmt::Write,
    ) -> std::fmt::Result {
        Uptime::default().style_timestamp(ansi, elapsed, w)
    }
}

pub fn init() -> Result<()> {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("rust_dive=info"));

    tracing_subscriber::registry()
        .with(filter)
        .with(
            HierarchicalLayer::new(2)
                .with_timer(LocalTimeMillis)
                .with_indent_lines(true)
                .with_targets(true)
                .with_thread_names(true),
        )
        .try_init()?;

    Ok(())
}
