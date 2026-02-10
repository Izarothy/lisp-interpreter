%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_EXIT 60

%define STDIN 0
%define STDOUT 1

%define LINE_BUF_SIZE 4096

global _start

section .bss
line_buf: resb LINE_BUF_SIZE

section .text
_start:
.repl:
    mov rdi, line_buf
    mov rsi, LINE_BUF_SIZE
    call read_line
    cmp rax, -1
    je .exit

    ; IO-only stage: parser/evaluator not wired yet.
    jmp .repl

.exit:
    xor rdi, rdi
    call sys_exit

; read_line(buffer=rdi, capacity=rsi) -> rax=len, -1 on EOF at start of line
; Stops at '\n' or EOF.
read_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    mov r12, rdi          ; buffer base
    xor rbx, rbx          ; index

.loop:
    cmp rbx, rsi
    jae .done

    lea rdi, [r12 + rbx]
    mov rsi, 1
    call sys_read
    cmp rax, 0
    je .eof
    cmp rax, 0
    jl .eof

    cmp byte [r12 + rbx], 10
    je .done_with_nl
    inc rbx
    jmp .loop

.eof:
    cmp rbx, 0
    je .eof_at_start
    jmp .done

.done_with_nl:
    inc rbx

.done:
    mov rax, rbx
    pop r12
    pop rbx
    pop rbp
    ret

.eof_at_start:
    mov rax, -1
    pop r12
    pop rbx
    pop rbp
    ret

; sys_read(buffer=rdi, len=rsi) -> rax
sys_read:
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, STDIN
    mov rax, SYS_READ
    syscall
    ret

; sys_write(buffer=rdi, len=rsi)
sys_write:
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, STDOUT
    mov rax, SYS_WRITE
    syscall
    ret

; sys_exit(code=rdi)
sys_exit:
    mov rax, SYS_EXIT
    syscall
