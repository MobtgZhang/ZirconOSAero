typedef unsigned long long u64;
typedef long long i64;

typedef struct {
    unsigned short length;
    unsigned short maximum_length;
    u64 buffer;
} UNICODE_STRING;

typedef struct {
    long long status;
    u64 information;
} IO_STATUS_BLOCK;

static i64 nt_display_string(const UNICODE_STRING *string) {
    i64 status;
    register long long first __asm__("r10") = (long long)string;
    __asm__ volatile ("syscall"
        : "=a"(status)
        : "a"(0xB8), "r"(first)
        : "rcx", "r11", "memory");
    return status;
}

static i64 nt_console_ioctl(unsigned long code,
    const void *input, unsigned long input_length,
    void *output, unsigned long output_length) {
    long long status;
    IO_STATUS_BLOCK io_status;
    io_status.status = 0;
    io_status.information = 0;
    register long long first __asm__("r10") = 0;
    register long long second __asm__("rdx") = 0;
    register long long third __asm__("r8") = 0;
    register long long fourth __asm__("r9") = 0;
    register long long ioctl_code __asm__("r15") = (long long)code;
    register long long input_ptr __asm__("r12") = (long long)input;
    register long long input_size __asm__("r13") = (long long)input_length;
    register long long output_ptr __asm__("r14") = (long long)output;
    register long long output_size __asm__("rbx") = (long long)output_length;
    __asm__ volatile (
        "subq $48, %%rsp\n"
        "movq %%rbx, 40(%%rsp)\n"
        "movq %%r14, 32(%%rsp)\n"
        "movq %%r13, 24(%%rsp)\n"
        "movq %%r12, 16(%%rsp)\n"
        "movq %%r15, 8(%%rsp)\n"
        "movq %1, (%%rsp)\n"
        "syscall\n"
        "addq $48, %%rsp\n"
        : "=a" (status)
        : "r" ((long long)&io_status),
          "r" (first), "r" (second), "r" (third), "r" (fourth),
          "r" (ioctl_code), "r" (input_ptr), "r" (input_size),
          "r" (output_ptr), "r" (output_size), "a"(0x52)
        : "rcx", "r11", "memory");
    return status;
}

static void print_ascii(const char *text) {
    unsigned short length = 0;
    static unsigned short wide[160];
    static UNICODE_STRING string;
    while (text[length] != 0 && length < 159) {
        wide[length] = (unsigned short)text[length];
        length++;
    }
    string.length = (unsigned short)(length * 2);
    string.maximum_length = string.length;
    string.buffer = (u64)wide;
    (void)nt_display_string(&string);
}

static unsigned char read_char(void) {
    unsigned char value = 0;
    if (nt_console_ioctl(0x80000001, 0, 0, &value, 1) == 0) {
        return value;
    }
    return 0;
}

static void write_ascii(const char *text) {
    unsigned long long length = 0;
    while (text[length] != 0) length++;
    (void)nt_console_ioctl(0x80000002, text, length, 0, 0);
}

static void nt_yield_execution(void) {
    long long status;
    __asm__ volatile ("syscall"
        : "=a"(status)
        : "a"(0x43)
        : "rcx", "r10", "r11", "memory");
    (void)status;
}

static void execute_command(const char *text) {
    unsigned long long length = 0;
    while (text[length] != 0) length++;
    (void)nt_console_ioctl(0x80000003, text, length, 0, 0);
}

static void show_prompt(void) {
    write_ascii("\r\nC:\\Users\\ZirconOS>");
}

__attribute__((noreturn)) void NtProcessStart(void) {
    static char line[256];
    unsigned long length = 0;

    print_ascii("Microsoft Windows [Version 6.1.7601]\r\n");
    print_ascii("(C) ZirconOS Project. Command interpreter (Ring 3).\r\n\r\n");
    show_prompt();

    for (;;) {
        const unsigned char ch = read_char();
        if (ch == 0) {
            register long long first __asm__("r10") = 0;
            register long long second __asm__("rdx") = 0;
            register long long third __asm__("r8") = 0;
            long long status;
            __asm__ volatile ("syscall"
                : "=a"(status)
            : "a"(0x04), "r"(first), "d"(second), "r"(third)
            : "rcx", "r11", "memory");
            nt_yield_execution();
            continue;
        }

        if (ch == '\r' || ch == '\n') {
            write_ascii("\r\n");
            if (length > 0) {
                line[length] = 0;
                execute_command(line);
                length = 0;
                line[0] = 0;
            }
            show_prompt();
            continue;
        }

        if (ch == 0x08 || ch == 0x7F) {
            if (length > 0) {
                length--;
                write_ascii("\x08 \x08");
            }
            continue;
        }

        if (length + 1 < sizeof(line)) {
            line[length++] = (char)ch;
            line[length] = 0;
            (void)write_ascii((const char[]){(char)ch, 0});
        }
    }
}
