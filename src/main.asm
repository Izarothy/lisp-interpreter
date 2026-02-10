%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_IOCTL 16
%define SYS_EXIT 60

%define STDIN 0
%define STDOUT 1
%define STDERR 2

%define EINTR_NEG -4
%define EIO_NEG -5

%define TCGETS 0x5401

%define LINE_BUF_SIZE 4096
%define IN_BUF_SIZE 16384
%define OUT_BUF_SIZE 64
%define STDOUT_BUF_SIZE 1048576

%define OP_ADD 1
%define OP_SUB 2
%define OP_MUL 3
%define OP_DIV 4

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
    mov al, [rsi]
    IS_WS_AL %%adv
    jmp %%done
%%adv:
    inc rsi
    jmp %%loop
%%done:
%endmacro

section .bss
in_buf: resb IN_BUF_SIZE
in_len: resq 1
in_pos: resq 1

line_buf: resb LINE_BUF_SIZE
out_buf: resb OUT_BUF_SIZE

stdout_buf: resb STDOUT_BUF_SIZE
stdout_used: resq 1

tty_probe: resb 64
interactive_mode: resq 1

err_code: resq 1

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

msg_fatal_read: db "fatal: stdin read failure", 10
msg_fatal_read_len: equ $ - msg_fatal_read

msg_fatal_stdout: db "fatal: stdout write failure", 10
msg_fatal_stdout_len: equ $ - msg_fatal_stdout

msg_fatal_stderr: db "fatal: stderr write failure", 10
msg_fatal_stderr_len: equ $ - msg_fatal_stderr

align 16
digits3:
%assign i 0
%rep 1000
    db '0' + (i / 100), '0' + ((i / 10) % 10), '0' + (i % 10)
%assign i i + 1
%endrep

section .text
_start:
    cld

    call detect_interactive

.repl:
    lea rdi, [rel line_buf]
    mov rsi, LINE_BUF_SIZE
    call read_line

    cmp rax, READLINE_EOF
    je .exit_ok
    cmp rax, READLINE_IO_ERROR
    je .fatal_read
    cmp rax, READLINE_TOO_LONG
    jne .have_line

    mov qword [err_code], ERR_LINE_TOO_LONG
    call flush_stdout
    test rax, rax
    js .fatal_stdout

    call print_error_line_stderr
    test rax, rax
    js .fatal_stderr
    jmp .repl

.have_line:
    lea rsi, [rel line_buf]
    lea rdi, [rsi + rax]
    call parse_line_eval

    cmp edx, 2
    je .repl
    cmp edx, 1
    jne .print_error

    mov rdi, rax
    call print_grouped_int_ln_stdout
    test rax, rax
    js .fatal_stdout
    jmp .repl

.print_error:
    call flush_stdout
    test rax, rax
    js .fatal_stdout

    call print_error_line_stderr
    test rax, rax
    js .fatal_stderr
    jmp .repl

.exit_ok:
    call flush_stdout
    test rax, rax
    js .fatal_stdout

    mov edi, EXIT_SUCCESS
    call sys_exit

.fatal_read:
    call flush_stdout
    test rax, rax
    js .fatal_stdout

    lea rdi, [rel msg_fatal_read]
    mov rsi, msg_fatal_read_len
    mov edx, EXIT_IO_ERROR
    call fatal_exit

.fatal_stdout:
    lea rdi, [rel msg_fatal_stdout]
    mov rsi, msg_fatal_stdout_len
    mov edx, EXIT_WRITE_ERROR
    call fatal_exit

.fatal_stderr:
    lea rdi, [rel msg_fatal_stderr]
    mov rsi, msg_fatal_stderr_len
    mov edx, EXIT_WRITE_ERROR
    call fatal_exit

; read_line(dest=rdi, capacity=rsi) -> rax
;   >=0 bytes in line buffer (includes newline if present)
;   -1 EOF at start
;   -2 line exceeded capacity (consumed/discarded through newline/EOF)
;   -3 read syscall failure
read_line:
    push rbx
    push r12
    push r13
    push r14
    push r15

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

    test r14, r14
    jnz .after_copy

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

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; parse_line_eval(line_start=rsi, line_end=rdi)
; -> rdx=1 success (rax=value), rdx=0 error, rdx=2 blank line/no-op
parse_line_eval:
    push rbx

    mov qword [err_code], ERR_NONE

    SKIP_WS
    cmp rsi, rdi
    jne .parse_expr

    xor eax, eax
    mov edx, 2
    jmp .done

.parse_expr:
    call parse_expr_eval
    cmp edx, 1
    jne .done

    mov rbx, rax
    SKIP_WS
    cmp rsi, rdi
    je .success

    mov qword [err_code], ERR_UNEXPECTED_TOKEN
    xor eax, eax
    xor edx, edx
    jmp .done

.success:
    mov rax, rbx
    mov edx, 1

.done:
    pop rbx
    ret

; parse_expr_eval(rsi=ptr, rdi=end) -> rdx=1 success (rax=value), rdx=0 failure
; updates rsi to next parse position on success.
parse_expr_eval:
    sub rsp, 8

    SKIP_WS
    cmp rsi, rdi
    jae .unexpected

    mov al, [rsi]
    cmp al, '('
    je .list

    call read_number_token
    test edx, edx
    jz .unexpected

    call parse_number_from_token
    cmp edx, 1
    jne .fail

    mov edx, 1
    jmp .done

.list:
    call parse_list_eval
    jmp .done

.unexpected:
    mov qword [err_code], ERR_UNEXPECTED_TOKEN

.fail:
    xor eax, eax
    xor edx, edx

.done:
    add rsp, 8
    ret

; parse_list_eval(rsi=ptr, rdi=end) -> rdx=1 success (rax=value), rdx=0 failure
; updates rsi to next parse position on success.
parse_list_eval:
    push rbx
    push r12
    push r13
    push r14
    push r15

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

    mov rbx, rsi
    call read_symbol_token
    test edx, edx
    jnz .symbol_form

    mov rsi, rbx
    call read_number_token
    test edx, edx
    jz .fail_unexpected

    call parse_number_from_token
    cmp edx, 1
    jne .fail_preserve
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
    ; r8=token_ptr rcx=token_len rsi=position after symbol
    call parse_op_token
    test eax, eax
    jz .fail_unknown
    mov r12, rax

    cmp rsi, rdi
    jae .boundary_ok

    mov al, [rsi]
    cmp al, ')'
    je .boundary_ok
    IS_WS_AL .boundary_ok
    jmp .fail_unknown

.boundary_ok:
    xor r14d, r14d          ; arg count
    xor r13d, r13d          ; accumulator

.arg_loop:
    SKIP_WS
    cmp rsi, rdi
    jae .fail_unmatched

    cmp byte [rsi], ')'
    je .close

    call parse_expr_eval
    cmp edx, 1
    jne .fail_preserve

    test r14, r14
    jnz .combine

    mov r13, rax
    mov r14, 1
    jmp .arg_loop

.combine:
    cmp r12, OP_ADD
    je .combine_add
    cmp r12, OP_SUB
    je .combine_sub
    cmp r12, OP_MUL
    je .combine_mul
    cmp r12, OP_DIV
    je .combine_div
    jmp .fail_unexpected

.combine_add:
    add r13, rax
    jo .fail_overflow
    inc r14
    jmp .arg_loop

.combine_sub:
    sub r13, rax
    jo .fail_overflow
    inc r14
    jmp .arg_loop

.combine_mul:
    imul r13, rax
    jo .fail_overflow
    inc r14
    jmp .arg_loop

.combine_div:
    mov r15, rax
    test r15, r15
    je .fail_div_zero

    cmp r15, -1
    jne .do_div
    mov rax, 0x8000000000000000
    cmp r13, rax
    je .fail_overflow

.do_div:
    mov rax, r13
    cqo
    idiv r15
    mov r13, rax
    inc r14
    jmp .arg_loop

.close:
    test r14, r14
    jz .fail_missing

    inc rsi

    cmp r12, OP_DIV
    jne .check_sub
    cmp r14, 2
    jb .fail_missing

.check_sub:
    cmp r12, OP_SUB
    jne .return_acc
    cmp r14, 1
    jne .return_acc

    mov rax, 0x8000000000000000
    cmp r13, rax
    je .fail_overflow
    neg r13

.return_acc:
    mov rax, r13
    mov edx, 1
    jmp .ok

.fail_unmatched:
    mov qword [err_code], ERR_UNMATCHED_PAREN
    jmp .fail_common

.fail_missing:
    mov qword [err_code], ERR_MISSING_ARGUMENTS
    jmp .fail_common

.fail_unknown:
    mov qword [err_code], ERR_UNKNOWN_SYMBOL
    jmp .fail_common

.fail_unexpected:
    mov qword [err_code], ERR_UNEXPECTED_TOKEN
    jmp .fail_common

.fail_div_zero:
    mov qword [err_code], ERR_DIV_ZERO
    jmp .fail_common

.fail_overflow:
    mov qword [err_code], ERR_OVERFLOW
    jmp .fail_common

.fail_preserve:
.fail_common:
    xor eax, eax
    xor edx, edx

.ok:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; read symbol token [a-z]+.
; in:  rsi=ptr, rdi=end
; out: rdx=1 success (r8=token_ptr, rcx=token_len, rsi=after token)
;      rdx=0 failure (rsi unchanged)
read_symbol_token:
    cmp rsi, rdi
    jae .none

    mov al, [rsi]
    cmp al, 'a'
    jb .none
    cmp al, 'z'
    ja .none

    mov r8, rsi

.loop:
    cmp rsi, rdi
    jae .done

    mov al, [rsi]
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    ja .done
    inc rsi
    jmp .loop

.done:
    mov rcx, rsi
    sub rcx, r8
    mov edx, 1
    ret

.none:
    xor edx, edx
    ret

; read number token '-'? [0-9]+.
; in:  rsi=ptr, rdi=end
; out: rdx=1 success (r8=token_ptr, rcx=token_len, rsi=after token)
;      rdx=0 failure (rsi unchanged)
read_number_token:
    cmp rsi, rdi
    jae .none

    mov r8, rsi
    mov rax, rsi

    cmp byte [rax], '-'
    jne .check_first_digit
    inc rax
    cmp rax, rdi
    jae .none

.check_first_digit:
    mov dl, [rax]
    cmp dl, '0'
    jb .none
    cmp dl, '9'
    ja .none

    inc rax

.digit_loop:
    cmp rax, rdi
    jae .finish

    mov dl, [rax]
    cmp dl, '0'
    jb .finish
    cmp dl, '9'
    ja .finish
    inc rax
    jmp .digit_loop

.finish:
    mov rsi, rax
    mov rcx, rax
    sub rcx, r8
    mov edx, 1
    ret

.none:
    xor edx, edx
    ret

; parse_number_from_token: parse signed decimal int64 from token.
; in:  r8=token_ptr, rcx=token_len
; out: rdx=1 success (rax=value), rdx=0 failure (err_code set)
parse_number_from_token:
    test rcx, rcx
    jz .empty_token

    mov rsi, r8
    xor eax, eax

    cmp byte [rsi], '-'
    jne .parse_positive

    inc rsi
    dec rcx
    jz .empty_token

.neg_loop:
    movzx rdx, byte [rsi]
    sub rdx, '0'

    imul rax, rax, 10
    jo .overflow

    sub rax, rdx
    jo .overflow

    inc rsi
    dec rcx
    jnz .neg_loop

    mov edx, 1
    ret

.parse_positive:
.pos_loop:
    movzx rdx, byte [rsi]
    sub rdx, '0'

    imul rax, rax, 10
    jo .overflow

    add rax, rdx
    jo .overflow

    inc rsi
    dec rcx
    jnz .pos_loop

    mov edx, 1
    ret

.empty_token:
    mov qword [err_code], ERR_UNEXPECTED_TOKEN
    xor eax, eax
    xor edx, edx
    ret

.overflow:
    mov qword [err_code], ERR_OVERFLOW
    xor eax, eax
    xor edx, edx
    ret

; parse_op_token
; in:  r8=token_ptr, rcx=token_len
; out: eax=opcode or 0
parse_op_token:
    cmp rcx, 3
    jne .unknown

    mov al, [r8]

    cmp al, 'a'
    je .check_add
    cmp al, 's'
    je .check_sub
    cmp al, 'm'
    je .check_mul
    cmp al, 'd'
    je .check_div
    jmp .unknown

.check_add:
    cmp byte [r8 + 1], 'd'
    jne .unknown
    cmp byte [r8 + 2], 'd'
    jne .unknown
    mov eax, OP_ADD
    ret

.check_sub:
    cmp byte [r8 + 1], 'u'
    jne .unknown
    cmp byte [r8 + 2], 'b'
    jne .unknown
    mov eax, OP_SUB
    ret

.check_mul:
    cmp byte [r8 + 1], 'u'
    jne .unknown
    cmp byte [r8 + 2], 'l'
    jne .unknown
    mov eax, OP_MUL
    ret

.check_div:
    cmp byte [r8 + 1], 'i'
    jne .unknown
    cmp byte [r8 + 2], 'v'
    jne .unknown
    mov eax, OP_DIV
    ret

.unknown:
    xor eax, eax
    ret

; print_grouped_int_ln_stdout(value=rdi) -> rax=0 success, <0 on write error
print_grouped_int_ln_stdout:
    push rbx

    mov rax, rdi
    mov rcx, rax
    sar rcx, 63
    mov r10d, ecx
    and r10d, 1
    xor rax, rcx
    sub rax, rcx

.mag_ready:
    lea r11, [rel out_buf + OUT_BUF_SIZE]
    dec r11
    mov byte [r11], 10
    mov r9, 1

    mov r8d, 1000
    cmp rax, 1000
    jb .write_head

.group_loop:
    xor edx, edx
    div r8

    mov ecx, edx
    lea rcx, [rcx + rcx * 2]
    lea rsi, [rel digits3]
    add rsi, rcx

    dec r11
    mov bl, [rsi + 2]
    mov [r11], bl
    dec r11
    mov bl, [rsi + 1]
    mov [r11], bl
    dec r11
    mov bl, [rsi]
    mov [r11], bl
    add r9, 3

    dec r11
    mov byte [r11], ','
    inc r9

    cmp rax, 1000
    jae .group_loop

.write_head:
    mov ecx, eax
    lea rcx, [rcx + rcx * 2]
    lea rsi, [rel digits3]
    add rsi, rcx

    cmp eax, 100
    jae .head_three
    cmp eax, 10
    jae .head_two

    dec r11
    mov bl, [rsi + 2]
    mov [r11], bl
    inc r9
    jmp .emit_sign

.head_two:
    dec r11
    mov bl, [rsi + 2]
    mov [r11], bl
    dec r11
    mov bl, [rsi + 1]
    mov [r11], bl
    add r9, 2
    jmp .emit_sign

.head_three:
    dec r11
    mov bl, [rsi + 2]
    mov [r11], bl
    dec r11
    mov bl, [rsi + 1]
    mov [r11], bl
    dec r11
    mov bl, [rsi]
    mov [r11], bl
    add r9, 3

.emit_sign:
    test r10d, r10d
    jz .emit

    dec r11
    mov byte [r11], '-'
    inc r9

.emit:
    mov rdi, r11
    mov rsi, r9
    call write_stdout_buffered

    pop rbx
    ret

; print_error_line_stderr -> rax=0 success, <0 on write error
print_error_line_stderr:
    sub rsp, 8

    mov rax, [err_code]

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
    call write_stderr_direct

    add rsp, 8
    ret

; write_stdout_buffered(ptr=rdi, len=rsi) -> rax=0 success, <0 error
write_stdout_buffered:
    push rbx
    push r12
    push r13

    test rsi, rsi
    jz .success

    mov r12, rdi
    mov r13, rsi

    mov rax, [interactive_mode]
    test rax, rax
    jz .buffered_path

    call flush_stdout
    test rax, rax
    js .done

    mov rdi, r12
    mov rsi, r13
    call write_stdout_direct
    jmp .done

.buffered_path:
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
    pop rbx
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

; detect_interactive: interactive_mode=1 if stdout is tty, else 0
detect_interactive:
    sub rsp, 8

    mov edi, STDOUT
    mov esi, TCGETS
    lea rdx, [rel tty_probe]
    call sys_ioctl_fd
    test rax, rax
    js .not_tty

    mov qword [interactive_mode], 1
    jmp .done

.not_tty:
    xor eax, eax
    mov [interactive_mode], rax

.done:
    add rsp, 8
    ret

; sys_read_fd(fd=rdi, buf=rsi, len=rdx) -> rax
sys_read_fd:
.retry:
    mov eax, SYS_READ
    syscall
    cmp rax, EINTR_NEG
    je .retry
    ret

; sys_write_fd(fd=rdi, buf=rsi, len=rdx) -> rax
sys_write_fd:
.retry:
    mov eax, SYS_WRITE
    syscall
    cmp rax, EINTR_NEG
    je .retry
    ret

; sys_ioctl_fd(fd=rdi, req=rsi, argp=rdx) -> rax
sys_ioctl_fd:
.retry:
    mov eax, SYS_IOCTL
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

; fatal_exit(msg_ptr=rdi, msg_len=rsi, exit_code=rdx)
fatal_exit:
    push rdx

    mov rdx, rsi
    mov rsi, rdi
    mov edi, STDERR
    call sys_write_all_fd

    pop rdi
    call sys_exit

; sys_exit(code=rdi)
sys_exit:
    mov eax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
