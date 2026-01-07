pub const TestContract = struct {
    pub fn add(a: i32) AddErrors!i32 {
        if (a > 5)
            return error.ValOver5;

        return a;
    }
};

pub const AddErrors = error{
    ValOver5,
};
