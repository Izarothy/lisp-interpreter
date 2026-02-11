%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_FSTAT 5
%define SYS_MMAP 9
%define SYS_EXIT 60

%define STDIN 0
%define STDOUT 1
%define STDERR 2

%define EINTR_NEG -4
%define EIO_NEG -5

%define LINE_LIMIT 65535
%define LINE_BUF_SIZE 65536
%define IN_BUF_SIZE 65536
%define OUT_BUF_SIZE 64
%define STDOUT_BUF_SIZE 1048576
%define STDERR_BUF_SIZE 262144

%define OP_ADD 1
%define OP_SUB 2
%define OP_MUL 3
%define OP_DIV 4

%define PARSE_STATUS_NONE 0
%define PARSE_STATUS_OK 1
%define PARSE_STATUS_OVERFLOW 2

%define ERR_NONE 0
%define ERR_UNEXPECTED_TOKEN 1
%define ERR_UNMATCHED_PAREN 2
%define ERR_MISSING_ARGUMENTS 3
%define ERR_UNKNOWN_SYMBOL 4
%define ERR_DIV_ZERO 5
%define ERR_OVERFLOW 6
%define ERR_LINE_TOO_LONG 7

%define READLINE_EOF -1
%define READLINE_TOO_LONG -2
%define READLINE_IO_ERROR -3

%define EXIT_SUCCESS 0
%define EXIT_IO_ERROR 1
%define EXIT_WRITE_ERROR 2

%define PROT_READ 1
%define MAP_PRIVATE 2

%define S_IFMT 0xF000
%define S_IFCHR 0x2000
%define S_IFREG 0x8000

%define STAT_OFF_MODE 24
%define STAT_OFF_RDEV 40
%define STAT_OFF_SIZE 48
%define STAT_BUF_SIZE 144
%define STAT_OFF_DEV 0

%define DEV_NULL_RDEV 0x103

%define INPUT_MODE_READ 0
%define INPUT_MODE_MMAP 1

%define SINK_STATE_NO 0
%define SINK_STATE_YES 1
%define SINK_STATE_UNKNOWN 2

default rel

global _start

%macro IS_WS_AL 1
    cmp al, ' '
    je %1
    cmp al, 9
    je %1
    cmp al, 10
    je %1
    cmp al, 13
    je %1
%endmacro

%macro SKIP_WS 0
%%loop:
    cmp rsi, rdi
    jae %%done
    mov dl, [rsi]
    cmp dl, ' '
    je %%adv
    ja %%done
    cmp dl, 9
    je %%adv
    cmp dl, 10
    je %%adv
    cmp dl, 13
    je %%adv
    jmp %%done
%%adv:
    inc rsi
    jmp %%loop
%%done:
%endmacro

; parse one expression in parse_list_eval fast path.
; success: rax=value, edx=PARSE_STATUS_OK
; failure jumps to parse_list_eval-local failure labels.
%macro PARSE_EXPR_REQ 0
    cmp byte [rsi], '('
    je %%list
    call parse_number_value
    cmp edx, PARSE_STATUS_OK
    je %%done
    cmp edx, PARSE_STATUS_OVERFLOW
    je .fail_overflow
    jmp .fail_unexpected
%%list:
    call parse_list_eval
    cmp edx, PARSE_STATUS_OK
    jne .fail_preserve
%%done:
%endmacro

section .bss
in_buf: resb IN_BUF_SIZE
in_len: resq 1
in_pos: resq 1

line_buf: resb LINE_BUF_SIZE
line_ptr: resq 1
out_buf: resb OUT_BUF_SIZE

stdout_buf: resb STDOUT_BUF_SIZE
stdout_used: resq 1

stderr_buf: resb STDERR_BUF_SIZE
stderr_used: resq 1

input_mode: resq 1
mmap_ptr: resq 1
mmap_len: resq 1

stdout_sink: resd 1
stderr_sink: resd 1

stat_buf: resb STAT_BUF_SIZE

err_code: resd 1

section .rodata
err_unexpected: db "error: unexpected token", 10
err_unexpected_len: equ $ - err_unexpected

err_unmatched: db "error: unmatched parenthesis", 10
err_unmatched_len: equ $ - err_unmatched

err_missing: db "error: missing arguments", 10
err_missing_len: equ $ - err_missing

err_unknown: db "error: unknown symbol", 10
err_unknown_len: equ $ - err_unknown

err_div_zero: db "error: division by zero", 10
err_div_zero_len: equ $ - err_div_zero

err_overflow: db "error: integer overflow", 10
err_overflow_len: equ $ - err_overflow

err_line_too_long: db "error: line too long", 10
err_line_too_long_len: equ $ - err_line_too_long

digit_pairs:
%assign __d 0
%rep 100
    db '0' + (__d / 10), '0' + (__d % 10)
%assign __d __d + 1
%endrep

section .text
_start:
    cld
    call init_sink_mode
    call init_input_mode

    cmp qword [input_mode], INPUT_MODE_MMAP
    je .mmap_repl

.repl:
    lea rdi, [rel line_buf]
    mov rsi, LINE_BUF_SIZE
    call read_line

    cmp rax, READLINE_EOF
    je .exit_ok
    cmp rax, READLINE_IO_ERROR
    je .exit_io_error
    cmp rax, READLINE_TOO_LONG
    jne .have_line

    mov dword [err_code], ERR_LINE_TOO_LONG
    cmp dword [stderr_sink], SINK_STATE_YES
    je .repl
    call print_error_line_stderr
    test rax, rax
    js .exit_write_error
    jmp .repl

.have_line:
    mov rsi, [line_ptr]
    lea rdi, [rsi + rax]
    SKIP_WS
    cmp rsi, rdi
    je .repl

    cmp byte [rsi], '('
    je .line_parse_list

    call parse_number_value
    cmp edx, PARSE_STATUS_OK
    je .line_expr_ok
    cmp edx, PARSE_STATUS_OVERFLOW
    je .line_parse_overflow
    mov dword [err_code], ERR_UNEXPECTED_TOKEN
    jmp .print_error

.line_parse_list:
    call parse_list_eval
    cmp edx, PARSE_STATUS_OK
    jne .print_error

.line_expr_ok:
    SKIP_WS
    cmp rsi, rdi
    je .line_parse_success
    mov dword [err_code], ERR_UNEXPECTED_TOKEN
    jmp .print_error

.line_parse_overflow:
    mov dword [err_code], ERR_OVERFLOW
    jmp .print_error

.line_parse_success:

    cmp dword [stdout_sink], SINK_STATE_YES
    je .repl

    mov rdi, rax
    call print_int_ln_stdout
    test rax, rax
    js .exit_write_error
    jmp .repl

.print_error:
    cmp dword [stderr_sink], SINK_STATE_YES
    je .repl
    call print_error_line_stderr
    test rax, rax
    js .exit_write_error
    jmp .repl

.mmap_repl:
    call process_mmap_input
    test rax, rax
    js .exit_write_error

.exit_ok:
    call flush_stdout
    test rax, rax
    js .exit_write_error

    call flush_stderr
    test rax, rax
    js .exit_write_error

    mov edi, EXIT_SUCCESS
    call sys_exit

.exit_io_error:
    mov edi, EXIT_IO_ERROR
    call sys_exit

.exit_write_error:
    mov edi, EXIT_WRITE_ERROR
    call sys_exit

; read_line(dest=rdi, capacity=rsi) -> rax
;   >=0 bytes in line buffer (includes newline if present)
;   -1 EOF at start
;   -2 line exceeded capacity (consumed/discarded through newline/EOF)
;   -3 read syscall failure
; internal fast path: clobbers callee-saved regs (called only from _start).
read_line:
    lea rax, [rel line_buf]
    mov [line_ptr], rax

    mov r12, rdi            ; destination pointer
    mov r13, rsi            ; destination capacity
    xor ebx, ebx            ; bytes written
    xor r14d, r14d          ; overflow flag
    mov r15, [in_pos]
    mov r10, [in_len]

.refill_or_process:
    cmp r15, r10
    jb .have_buffer_data

    mov edi, STDIN
    lea rsi, [rel in_buf]
    mov edx, IN_BUF_SIZE
    call sys_read_fd

    test rax, rax
    jz .eof
    js .read_error

    mov r10, rax
    xor r15d, r15d

.have_buffer_data:
    lea r8, [rel in_buf]
    add r8, r15
    mov r9, r10
    sub r9, r15             ; available bytes

    mov rdi, r8
    mov rcx, r9
    mov al, 10
    repne scasb
    setz r11b

    mov rdx, r9
    sub rdx, rcx            ; bytes to consume from input buffer

.scan_done:

    test r14, r14
    jnz .after_copy
    test r11b, r11b
    jz .copy_or_overflow
    test rbx, rbx
    jnz .copy_or_overflow
    cmp rdx, r13
    ja .copy_or_overflow

    mov [line_ptr], r8
    mov rbx, rdx
    add r15, rdx
    mov rax, rbx
    jmp .done

.copy_or_overflow:

    mov rax, r13
    sub rax, rbx            ; remaining destination capacity
    cmp rdx, rax
    jbe .copy_all

    test rax, rax
    jz .mark_overflow

    mov rcx, rax
    lea rdi, [r12 + rbx]
    mov rsi, r8
    rep movsb
    add rbx, rax

.mark_overflow:
    mov r14, 1
    jmp .after_copy

.copy_all:
    mov rcx, rdx
    lea rdi, [r12 + rbx]
    mov rsi, r8
    rep movsb
    add rbx, rdx

.after_copy:
    add r15, rdx

    test r11b, r11b
    jz .refill_or_process

    test r14, r14
    jnz .too_long

    mov rax, rbx
    jmp .done

.eof:
    test r14, r14
    jnz .too_long

    test rbx, rbx
    jz .eof_at_start

    cmp rbx, LINE_LIMIT
    ja .too_long

    mov rax, rbx
    jmp .done

.eof_at_start:
    mov rax, READLINE_EOF
    jmp .done

.read_error:
    mov rax, READLINE_IO_ERROR
    jmp .done

.too_long:
    mov rax, READLINE_TOO_LONG

.done:
    mov [in_pos], r15
    mov [in_len], r10

    ret

; process_mmap_input -> rax=0 success, <0 on write error
process_mmap_input:
    push rbx
    push r12
    push r14
    push r15

    mov ebx, dword [stdout_sink]
    mov r15, [mmap_ptr]
    mov rax, [mmap_len]
    lea r14, [r15 + rax]

.line_loop:
    cmp r15, r14
    jae .success

    mov rdi, r15
    mov rcx, r14
    sub rcx, r15
    mov al, 10
    repne scasb
    setz r11b
    mov r12, rdi
    sub r12, r15            ; bytes in this line chunk (includes newline if present)

    mov rax, r12            ; payload length excluding newline
    test r11b, r11b
    jz .check_length
    dec rax

.check_length:
    cmp rax, LINE_LIMIT
    ja .line_too_long

    mov rsi, r15
    lea rdi, [r15 + r12]
    SKIP_WS
    cmp rsi, rdi
    je .advance

    cmp byte [rsi], '('
    je .line_parse_list

    call parse_number_value
    cmp edx, PARSE_STATUS_OK
    je .line_expr_ok
    cmp edx, PARSE_STATUS_OVERFLOW
    je .line_parse_overflow
    mov dword [err_code], ERR_UNEXPECTED_TOKEN
    jmp .emit_error

.line_parse_list:
    call parse_list_eval
    cmp edx, PARSE_STATUS_OK
    jne .emit_error

.line_expr_ok:
    SKIP_WS
    cmp rsi, rdi
    je .line_parse_success
    mov dword [err_code], ERR_UNEXPECTED_TOKEN
    jmp .emit_error

.line_parse_overflow:
    mov dword [err_code], ERR_OVERFLOW
    jmp .emit_error

.line_parse_success:

    cmp ebx, SINK_STATE_YES
    je .advance

    mov rdi, rax
    call print_int_ln_stdout
    test rax, rax
    js .fail
    jmp .advance

.emit_error:
    cmp dword [stderr_sink], SINK_STATE_YES
    je .advance
    call print_error_line_stderr
    test rax, rax
    js .fail
    jmp .advance

.line_too_long:
    mov dword [err_code], ERR_LINE_TOO_LONG
    cmp dword [stderr_sink], SINK_STATE_YES
    je .advance
    call print_error_line_stderr
    test rax, rax
    js .fail

.advance:
    add r15, r12
    jmp .line_loop

.success:
    xor eax, eax

.done:
    pop r15
    pop r14
    pop r12
    pop rbx
    ret

.fail:
    ; propagate negative write failure from buffered/direct write path.
    jmp .done

; parse_list_eval(rsi=ptr, rdi=end) -> rdx=1 success (rax=value), rdx=0 failure
; updates rsi to next parse position on success.
parse_list_eval:
    push r12
    push r13

    cmp rsi, rdi
    jae .fail_unexpected
    cmp byte [rsi], '('
    jne .fail_unexpected
    inc rsi

    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched

    cmp byte [rsi], ')'
    je .fail_missing

    movzx eax, byte [rsi]
    cmp eax, 'a'
    jb .maybe_singleton_number
    cmp eax, 'z'
    ja .maybe_singleton_number

    lea r11, [rsi + 3]
    cmp r11, rdi
    ja .fail_unknown

    cmp eax, 'a'
    je .op_add
    cmp eax, 's'
    je .op_sub
    cmp eax, 'm'
    je .op_mul
    cmp eax, 'd'
    je .op_div
    jmp .fail_unknown

.op_add:
    cmp byte [rsi + 1], 'd'
    jne .fail_unknown
    cmp byte [rsi + 2], 'd'
    jne .fail_unknown
    mov r12d, OP_ADD
    jmp .op_boundary

.op_sub:
    cmp byte [rsi + 1], 'u'
    jne .fail_unknown
    cmp byte [rsi + 2], 'b'
    jne .fail_unknown
    mov r12d, OP_SUB
    jmp .op_boundary

.op_mul:
    cmp byte [rsi + 1], 'u'
    jne .fail_unknown
    cmp byte [rsi + 2], 'l'
    jne .fail_unknown
    mov r12d, OP_MUL
    jmp .op_boundary

.op_div:
    cmp byte [rsi + 1], 'i'
    jne .fail_unknown
    cmp byte [rsi + 2], 'v'
    jne .fail_unknown
    mov r12d, OP_DIV

.op_boundary:
    cmp r11, rdi
    jae .op_ok
    movzx ecx, byte [r11]
    cmp ecx, ')'
    je .op_ok
    cmp ecx, ' '
    je .op_ok
    cmp ecx, 9
    je .op_ok
    cmp ecx, 10
    je .op_ok
    cmp ecx, 13
    jne .fail_unknown

.op_ok:
    mov rsi, r11
    jmp .symbol_form

.maybe_singleton_number:
    call parse_number_value
    cmp edx, PARSE_STATUS_OK
    je .have_singleton
    cmp edx, PARSE_STATUS_OVERFLOW
    je .fail_overflow
    jmp .fail_unexpected

.have_singleton:
    mov r13, rax

    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    jne .fail_unexpected

    inc rsi
    mov rax, r13
    mov edx, 1
    jmp .ok

.symbol_form:
    ; Parse first argument once, then run an opcode-specialized loop.
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .fail_missing

    PARSE_EXPR_REQ

    mov r13, rax
    cmp r12, OP_ADD
    je .add_loop
    cmp r12, OP_MUL
    je .mul_loop
    cmp r12, OP_SUB
    je .sub_after_first
    jmp .div_need_rhs

align 16
.add_loop:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .close_return
    PARSE_EXPR_REQ
    add r13, rax
    jo .fail_overflow
    jmp .add_loop

align 16
.mul_loop:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .close_return
    PARSE_EXPR_REQ
    imul r13, rax
    jo .fail_overflow
    jmp .mul_loop

.sub_after_first:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .sub_unary_close
    PARSE_EXPR_REQ
    sub r13, rax
    jo .fail_overflow
    jmp .sub_loop

align 16
.sub_loop:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .close_return
    PARSE_EXPR_REQ
    sub r13, rax
    jo .fail_overflow
    jmp .sub_loop

.sub_unary_close:
    inc rsi
    mov rax, 0x8000000000000000
    cmp r13, rax
    je .fail_overflow
    neg r13
    jmp .return_acc

.div_need_rhs:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .fail_missing
    PARSE_EXPR_REQ

.div_apply:
    mov rcx, rax
    test rcx, rcx
    je .fail_div_zero
    cmp rcx, -1
    jne .do_div
    mov rax, 0x8000000000000000
    cmp r13, rax
    je .fail_overflow

.do_div:
    mov rax, r13
    cqo
    idiv rcx
    mov r13, rax
    jmp .div_loop

align 16
.div_loop:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched
    cmp byte [rsi], ')'
    je .close_return
    PARSE_EXPR_REQ
    jmp .div_apply

.close_return:
    inc rsi

.return_acc:
    mov rax, r13
    mov edx, PARSE_STATUS_OK
    jmp .ok

.fail_unmatched:
    mov dword [err_code], ERR_UNMATCHED_PAREN
    jmp .fail_common

.fail_missing:
    mov dword [err_code], ERR_MISSING_ARGUMENTS
    jmp .fail_common

.fail_unknown:
    mov dword [err_code], ERR_UNKNOWN_SYMBOL
    jmp .fail_common

.fail_unexpected:
    mov dword [err_code], ERR_UNEXPECTED_TOKEN
    jmp .fail_common

.fail_div_zero:
    mov dword [err_code], ERR_DIV_ZERO
    jmp .fail_common

.fail_overflow:
    mov dword [err_code], ERR_OVERFLOW
    jmp .fail_common

.fail_preserve:
.fail_common:
    xor eax, eax
    xor edx, edx

.ok:
    pop r13
    pop r12
    ret

; parse_number_value: parse signed decimal int64 directly from input stream.
; in:  rsi=ptr, rdi=end
; out: rdx=1 success (rax=value, rsi advanced)
;      rdx=0 no-number (rsi unchanged)
;      rdx=2 overflow
parse_number_value:
    cmp rsi, rdi
    jae .none

    mov r10, rsi
    mov r11, rsi
    xor r8d, r8d            ; 1 => negative number

    cmp byte [r11], '-'
    jne .first_digit
    mov r8d, 1
    inc r11
    cmp r11, rdi
    jae .none_restore

.first_digit:
    movzx edx, byte [r11]
    sub edx, '0'
    cmp edx, 9
    ja .none_restore

    xor eax, eax
    mov rcx, 922337203685477580

.digit_loop:
    cmp rax, rcx
    ja .overflow
    jb .acc_ok
    cmp edx, 8
    ja .overflow

.acc_ok:
    lea rax, [rax + rax*4]
    lea rax, [rdx + rax*2]
    inc r11
    cmp r11, rdi
    jae .digits_done
    movzx edx, byte [r11]
    sub edx, '0'
    cmp edx, 9
    jbe .digit_loop

.digits_done:
    test r8d, r8d
    jz .final_pos

    mov rcx, 0x8000000000000000
    cmp rax, rcx
    ja .overflow
    je .final_ok
    neg rax
    jmp .final_ok

.final_pos:
    mov rcx, 0x7fffffffffffffff
    cmp rax, rcx
    ja .overflow

.final_ok:
    mov rsi, r11
    mov edx, PARSE_STATUS_OK
    ret

.overflow:
    xor eax, eax
    mov edx, PARSE_STATUS_OVERFLOW
    ret

.none_restore:
    mov rsi, r10

.none:
    xor eax, eax
    xor edx, edx
    ret

; print_int_ln_stdout(value=rdi) -> rax=0 success, <0 on write error
print_int_ln_stdout:
    lea r9, [rel out_buf + OUT_BUF_SIZE]
    dec r9
    mov byte [r9], 10

    mov rax, rdi
    xor r10d, r10d
    test rax, rax
    js .neg_value
    cmp rax, 100
    jae .abs_ready
    cmp rax, 10
    jb .fast_one_digit
    mov ecx, eax
    add ecx, ecx
    lea rdx, [rel digit_pairs]
    mov ax, word [rdx + rcx]
    sub r9, 2
    mov word [r9], ax
    jmp .maybe_sign

.neg_value:
    mov r10d, 1
    neg rax
    jns .abs_ready
    ; INT64_MIN special case.
    mov rax, 0x8000000000000000

.abs_ready:
    cmp rax, 0
    jne .digit_loop
    jmp .fast_one_digit

.digit_loop:
    cmp rax, 100
    jae .digit_loop_div

    cmp rax, 10
    jb .fast_one_digit

    mov ecx, eax
    add ecx, ecx
    lea rdx, [rel digit_pairs]
    mov ax, word [rdx + rcx]
    sub r9, 2
    mov word [r9], ax
    jmp .maybe_sign

.fast_one_digit:
    add al, '0'
    dec r9
    mov [r9], al
    jmp .maybe_sign

.digit_loop_div:
    mov r8d, 10
.digit_loop_div_iter:
    xor edx, edx
    div r8
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .digit_loop_div_iter

.maybe_sign:
    test r10d, r10d
    jz .emit
    dec r9
    mov byte [r9], '-'

.emit:
    mov rdi, r9
    lea rsi, [rel out_buf + OUT_BUF_SIZE]
    sub rsi, r9
    call write_stdout_buffered
    ret

; print_error_line_stderr -> rax=0 success, <0 on write error
print_error_line_stderr:
    sub rsp, 8

    mov eax, dword [stderr_sink]
    cmp eax, SINK_STATE_YES
    je .sink_success
    cmp eax, SINK_STATE_UNKNOWN
    jne .have_stderr_sink
    call detect_stderr_sink
    cmp dword [stderr_sink], SINK_STATE_YES
    je .sink_success

.have_stderr_sink:
    mov eax, dword [err_code]

    cmp rax, ERR_UNMATCHED_PAREN
    je .unmatched
    cmp rax, ERR_MISSING_ARGUMENTS
    je .missing
    cmp rax, ERR_UNKNOWN_SYMBOL
    je .unknown
    cmp rax, ERR_DIV_ZERO
    je .div_zero
    cmp rax, ERR_OVERFLOW
    je .overflow
    cmp rax, ERR_LINE_TOO_LONG
    je .line_too_long

    lea rdi, [rel err_unexpected]
    mov rsi, err_unexpected_len
    jmp .emit

.unmatched:
    lea rdi, [rel err_unmatched]
    mov rsi, err_unmatched_len
    jmp .emit

.missing:
    lea rdi, [rel err_missing]
    mov rsi, err_missing_len
    jmp .emit

.unknown:
    lea rdi, [rel err_unknown]
    mov rsi, err_unknown_len
    jmp .emit

.div_zero:
    lea rdi, [rel err_div_zero]
    mov rsi, err_div_zero_len
    jmp .emit

.overflow:
    lea rdi, [rel err_overflow]
    mov rsi, err_overflow_len
    jmp .emit

.line_too_long:
    lea rdi, [rel err_line_too_long]
    mov rsi, err_line_too_long_len

.emit:
    call write_stderr_buffered
    jmp .done

.sink_success:
    xor eax, eax

.done:
    add rsp, 8
    ret

; write_stdout_buffered(ptr=rdi, len=rsi) -> rax=0 success, <0 error
write_stdout_buffered:
    push r12
    push r13

    test rsi, rsi
    jz .success

    mov r12, rdi
    mov r13, rsi

    cmp r13, STDOUT_BUF_SIZE
    jbe .fit_buffer

    call flush_stdout
    test rax, rax
    js .done

    mov rdi, r12
    mov rsi, r13
    call write_stdout_direct
    jmp .done

.fit_buffer:
    mov rax, [stdout_used]
    mov rcx, STDOUT_BUF_SIZE
    sub rcx, rax
    cmp r13, rcx
    jbe .copy_into_buffer

    call flush_stdout
    test rax, rax
    js .done

.copy_into_buffer:
    mov rax, [stdout_used]
    lea rdi, [rel stdout_buf]
    add rdi, rax
    mov rsi, r12
    mov rcx, r13
    rep movsb

    mov rax, [stdout_used]
    add rax, r13
    mov [stdout_used], rax

.success:
    xor eax, eax

.done:
    pop r13
    pop r12
    ret

; flush_stdout -> rax=0 success, <0 error
flush_stdout:
    sub rsp, 8

    mov rsi, [stdout_used]
    test rsi, rsi
    jz .success

    lea rdi, [rel stdout_buf]
    call write_stdout_direct
    test rax, rax
    js .done

    xor eax, eax
    mov [stdout_used], rax

.success:
    xor eax, eax

.done:
    add rsp, 8
    ret

; write_stderr_buffered(ptr=rdi, len=rsi) -> rax=0 success, <0 error
write_stderr_buffered:
    push r12
    push r13

    test rsi, rsi
    jz .success

    mov r12, rdi
    mov r13, rsi

    cmp r13, STDERR_BUF_SIZE
    jbe .fit_buffer

    call flush_stderr
    test rax, rax
    js .done

    mov rdi, r12
    mov rsi, r13
    call write_stderr_direct
    jmp .done

.fit_buffer:
    mov rax, [stderr_used]
    mov rcx, STDERR_BUF_SIZE
    sub rcx, rax
    cmp r13, rcx
    jbe .copy_into_buffer

    call flush_stderr
    test rax, rax
    js .done

.copy_into_buffer:
    mov rax, [stderr_used]
    lea rdi, [rel stderr_buf]
    add rdi, rax
    mov rsi, r12
    mov rcx, r13
    rep movsb

    mov rax, [stderr_used]
    add rax, r13
    mov [stderr_used], rax

.success:
    xor eax, eax

.done:
    pop r13
    pop r12
    ret

; flush_stderr -> rax=0 success, <0 error
flush_stderr:
    sub rsp, 8

    mov rsi, [stderr_used]
    test rsi, rsi
    jz .success

    lea rdi, [rel stderr_buf]
    call write_stderr_direct
    test rax, rax
    js .done

    xor eax, eax
    mov [stderr_used], rax

.success:
    xor eax, eax

.done:
    add rsp, 8
    ret

; write_stdout_direct(ptr=rdi, len=rsi) -> rax=0 success, <0 error
write_stdout_direct:
    sub rsp, 8

    mov rdx, rsi
    mov rsi, rdi
    mov edi, STDOUT
    call sys_write_all_fd

    add rsp, 8
    ret

; write_stderr_direct(ptr=rdi, len=rsi) -> rax=0 success, <0 error
write_stderr_direct:
    sub rsp, 8

    mov rdx, rsi
    mov rsi, rdi
    mov edi, STDERR
    call sys_write_all_fd

    add rsp, 8
    ret

; init_sink_mode:
;   stdout_sink is detected eagerly (hot success path).
;   stderr_sink is deferred until first error print.
init_sink_mode:
    mov dword [stdout_sink], SINK_STATE_NO
    mov dword [stderr_sink], SINK_STATE_UNKNOWN

    mov edi, STDOUT
    lea rsi, [rel stat_buf]
    call sys_fstat_fd
    test rax, rax
    js .done

    lea rdi, [rel stat_buf]
    call stat_is_dev_null
    mov dword [stdout_sink], eax

.done:
    ret

; detect_stderr_sink:
;   Sets stderr_sink to SINK_STATE_NO or SINK_STATE_YES.
detect_stderr_sink:
    mov edi, STDERR
    lea rsi, [rel stat_buf]
    call sys_fstat_fd
    test rax, rax
    js .set_no

    lea rdi, [rel stat_buf]
    call stat_is_dev_null
    mov dword [stderr_sink], eax
    ret

.set_no:
    mov dword [stderr_sink], SINK_STATE_NO
    ret

; init_input_mode:
;   Uses mmap when stdin is a regular file with known size, else falls back to read().
init_input_mode:
    xor eax, eax
    mov [input_mode], rax
    mov [mmap_ptr], rax
    mov [mmap_len], rax

    mov edi, STDIN
    lea rsi, [rel stat_buf]
    call sys_fstat_fd
    test rax, rax
    js .done

    mov eax, dword [rel stat_buf + STAT_OFF_MODE]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .done

    mov rsi, [rel stat_buf + STAT_OFF_SIZE]
    test rsi, rsi
    js .done
    jz .zero_len

    ; Adaptive mmap threshold based on st_dev major:
    ; major==0 typically maps to WSL DrvFS/9p -> keep a larger cutoff.
    mov rax, [rel stat_buf + STAT_OFF_DEV]
    shr rax, 8
    and eax, 0xfff
    test eax, eax
    jz .threshold_v9fs_like
    cmp rsi, 8192
    jb .done
    jmp .map_input

.threshold_v9fs_like:
    cmp rsi, 32768
    jb .done

.map_input:

    xor edi, edi            ; addr = NULL
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE
    mov r8d, STDIN          ; fd = 0
    xor r9d, r9d            ; offset = 0
    call sys_mmap
    test rax, rax
    js .done

    mov [mmap_ptr], rax
    mov rax, [rel stat_buf + STAT_OFF_SIZE]
    mov [mmap_len], rax
    mov qword [input_mode], INPUT_MODE_MMAP
    ret

.zero_len:
    mov qword [input_mode], INPUT_MODE_MMAP

.done:
    ret

; stat_is_dev_null(stat_ptr=rdi) -> eax=1 if character device /dev/null, else 0.
stat_is_dev_null:
    mov eax, dword [rdi + STAT_OFF_MODE]
    and eax, S_IFMT
    cmp eax, S_IFCHR
    jne .no

    mov rax, [rdi + STAT_OFF_RDEV]
    cmp rax, DEV_NULL_RDEV
    jne .no

    mov eax, 1
    ret

.no:
    xor eax, eax
    ret

; sys_read_fd(fd=rdi, buf=rsi, len=rdx) -> rax
sys_read_fd:
.retry:
    mov eax, SYS_READ
    syscall
    cmp rax, EINTR_NEG
    je .retry
    ret

; sys_fstat_fd(fd=rdi, stat_ptr=rsi) -> rax
sys_fstat_fd:
.retry:
    mov eax, SYS_FSTAT
    syscall
    cmp rax, EINTR_NEG
    je .retry
    ret

; sys_mmap(addr=rdi, len=rsi, prot=rdx, flags=r10, fd=r8, offset=r9) -> rax
sys_mmap:
    mov eax, SYS_MMAP
    syscall
    ret

; sys_write_fd(fd=rdi, buf=rsi, len=rdx) -> rax
sys_write_fd:
.retry:
    mov eax, SYS_WRITE
    syscall
    cmp rax, EINTR_NEG
    je .retry
    ret

; sys_write_all_fd(fd=rdi, buf=rsi, len=rdx) -> rax
; returns 0 on success, negative errno-like code on failure.
sys_write_all_fd:
    push r12
    push r13
    push r14

    mov r12, rdi
    mov r13, rsi
    mov r14, rdx

.loop:
    test r14, r14
    jz .success

    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call sys_write_fd

    test rax, rax
    js .fail
    jz .fail_zero

    add r13, rax
    sub r14, rax
    jmp .loop

.success:
    xor eax, eax
    jmp .done

.fail_zero:
    mov rax, EIO_NEG

.fail:
.done:
    pop r14
    pop r13
    pop r12
    ret

; sys_exit(code=rdi)
sys_exit:
    mov eax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
