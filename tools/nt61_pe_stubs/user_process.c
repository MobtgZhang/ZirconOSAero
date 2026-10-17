typedef unsigned long long u64;
typedef long long i64;

typedef struct {
    unsigned short length;
    unsigned short maximum_length;
    u64 buffer;
} UNICODE_STRING;

static i64 nt_display_string(const UNICODE_STRING *string) {
    long long status;
    register long long first __asm__("r10") = (long long)string;
    __asm__ volatile ("syscall"
        : "=a"(status)
        : "a"(0xB8), "r"(first)
        : "rcx", "r11", "memory");
    return status;
}

static void print_ascii(const char *text) {
    unsigned short length = 0;
    static unsigned short wide[128];
    static UNICODE_STRING string;
    while (text[length] != 0 && length < 127) {
        wide[length] = (unsigned short)text[length];
        length++;
    }
    string.length = (unsigned short)(length * 2);
    string.maximum_length = string.length;
    string.buffer = (u64)wide;
    (void)nt_display_string(&string);
}

static void nt_yield_execution(void) {
    long long status;
    __asm__ volatile ("syscall"
        : "=a"(status)
        : "a"(0x43)
        : "rcx", "r10", "r11", "memory");
    (void)status;
}

__attribute__((noreturn)) void NtProcessStart(void) {
    print_ascii(PROCESS_NAME);
    print_ascii(": Ring 3 process ready\r\n");
    for (;;) {
        nt_yield_execution();
        register long long first __asm__("r10") = 0;
        register long long second __asm__("rdx") = 0;
        register long long third __asm__("r8") = 0;
        long long status;
        __asm__ volatile ("syscall"
            : "=a"(status)
            : "a"(0x04), "r"(first), "d"(second), "r"(third)
            : "rcx", "r11", "memory");
        nt_yield_execution();
    }
}
