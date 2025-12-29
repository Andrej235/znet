pub const CountingSerializationErrors = error{
    InvalidUnionTag,
};

pub const SerializationErrors = error{
    InvalidUnionTag,
    NoSpaceLeft,
    IntegerSerializationFailed,
};

pub const DeserializationErrors = error{
    InvalidUnionTag,
    UnexpectedEof,
    AllocationFailed,
    OutOfMemory,
    EndOfStream,
    InvalidBooleanValue,
    IntegerDeserializationFailed,
    BooleanDeserializationFailed,
};
