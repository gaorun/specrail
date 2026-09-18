const build_options = @import("build_options");

pub fn packageVersion() []const u8 {
    return build_options.version;
}
