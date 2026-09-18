pub const Error = error{
    HelpRequested,
    VersionRequested,
    Usage,
    Distribute,
    OutOfMemory,
};

/// Message printed for the most recent error.Usage / error.Distribute failure.
pub var message: []const u8 = "";
