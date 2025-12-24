pub const SerializationErrors = error{
    InvalidUnionTag,
    NoSpaceLeft,
};

pub const DeserializationErrors = error{
    InvalidUnionTag,
    UnexpectedEof,
    AllocationFailed,
    OutOfMemory,
    EndOfStream,
    InvalidBooleanValue,
};
