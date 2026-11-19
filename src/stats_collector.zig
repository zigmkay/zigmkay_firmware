const core = @import("core.zig");
pub const StatsCollector = struct {
    counter: u64 = 0,
    last_reset_time_us: u64 = 0,
    previous_count: u64 = 0,
    lowest_count: u64 = 0,
    highest_count: u64 = 0,
    pub fn register_tick(self: *StatsCollector, current_time: core.TimeSinceBoot) bool {
        if (current_time.time_since_boot_us - self.last_reset_time_us > 1000000) {
            if (self.counter < self.lowest_count) {
                self.lowest_count = self.counter;
            }
            if (self.counter > self.highest_count) {
                self.highest_count = self.counter;
            }
            if (self.previous_count == 0) {
                self.lowest_count = self.counter;
                self.highest_count = self.counter;
            }

            self.previous_count = self.counter;
            self.counter = 1;
            self.last_reset_time_us = current_time.time_since_boot_us;
            return true;
        } else {
            self.counter += 1;
            return false;
        }
    }
    pub fn get_tick_rate(self: StatsCollector) u64 {
        return self.previous_count;
    }
    pub fn get_highest_count(self: StatsCollector) u64 {
        return self.highest_count;
    }
    pub fn get_lowest_count(self: StatsCollector) u64 {
        return self.lowest_count;
    }
};
