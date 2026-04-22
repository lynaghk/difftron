mod demo {
    use std::fmt::Debug;
    use std::num::NonZeroI32;

    pub fn compute(input: i32) -> i32 {
        let bonus = NonZeroI32::new(input.abs()).map_or(0, NonZeroI32::get);
        input + bonus
    }

    pub fn render<T: Debug>(value: T) -> String {
        format!("{value:?}")
    }
}
