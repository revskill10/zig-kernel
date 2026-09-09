pub const KernelError = error{
    NoMem, NotFound, AlreadyExists, InvalidArg, NotSupported,
    Permission, Busy, NoDevice, Timeout, Overflow, Again, NotConn,
};

pub const Errno = enum(i32) {
    ok = 0, nomem = -12, notfound = -2, exists = -17, inval = -22,
    nosys = -38, perm = -1, busy = -16, nodev = -19, timedout = -110,
    again = -11,
};

pub fn toErrno(e: KernelError) Errno {
    return switch (e) {
        error.NoMem => .nomem, error.NotFound => .notfound, error.AlreadyExists => .exists,
        error.InvalidArg => .inval, error.NotSupported => .nosys, error.Permission => .perm,
        error.Busy => .busy, error.NoDevice => .nodev, error.Timeout => .timedout,
        error.Again => .again, error.Overflow => .inval,
    };
}
