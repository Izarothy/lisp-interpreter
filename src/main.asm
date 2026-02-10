%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_EXIT 60

%define STDIN 0
%define STDOUT 1

%define LINE_BUF_SIZE 4096

global _start

section .bss
line_buf: resb LINE_BUF_SIZE
line_len: resq 1
parse_pos: resq 1
tok_ptr: resq 1
tok_len: resq 1

section .text
_start:
.repl:
    mov rdi, line_buf
    mov rsi, LINE_BUF_SIZE
    call read_line
    cmp rax, -1
    je .exit
    mov [line_len], rax
    mov qword [parse_pos], 0

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

; skip spaces/tabs/newlines at parse_pos
skip_ws:
    push rbx
.loop:
    mov rbx, [parse_pos]
    cmp rbx, [line_len]
    jae .done
    mov al, [line_buf + rbx]
    cmp al, ' '
    je .advance
    cmp al, 9
    je .advance
    cmp al, 10
    je .advance
    cmp al, 13
    je .advance
    jmp .done
.advance:
    inc rbx
    mov [parse_pos], rbx
    jmp .loop
.done:
    pop rbx
    ret

; peek current char in al, 0 if at end
peek_char:
    mov rax, [parse_pos]
    cmp rax, [line_len]
    jae .eof
    mov al, [line_buf + rax]
    ret
.eof:
    xor eax, eax
    ret

; advance parse_pos by 1 if not at end
advance_char:
    mov rax, [parse_pos]
    cmp rax, [line_len]
    jae .done
    inc rax
    mov [parse_pos], rax
.done:
    ret

; read symbol token [a-z]+ into tok_ptr/tok_len
; returns rax=1 if token read, rax=0 otherwise
read_symbol_token:
    push rbx
    push rcx
    mov rbx, [parse_pos]
    cmp rbx, [line_len]
    jae .none
    mov al, [line_buf + rbx]
    cmp al, 'a'
    jb .none
    cmp al, 'z'
    ja .none
    mov [tok_ptr], rbx
    xor rcx, rcx
.sym_loop:
    mov rax, rbx
    add rax, rcx
    cmp rax, [line_len]
    jae .finish
    mov al, [line_buf + rax]
    cmp al, 'a'
    jb .finish
    cmp al, 'z'
    ja .finish
    inc rcx
    jmp .sym_loop
.finish:
    mov [tok_len], rcx
    add rbx, rcx
    mov [parse_pos], rbx
    mov rax, 1
    pop rcx
    pop rbx
    ret
.none:
    xor eax, eax
    pop rcx
    pop rbx
    ret

; read number token '-'? [0-9]+ into tok_ptr/tok_len
; returns rax=1 if token read, rax=0 otherwise
read_number_token:
    push rbx
    push rcx
    mov rbx, [parse_pos]
    cmp rbx, [line_len]
    jae .none

    mov rcx, rbx
    mov al, [line_buf + rcx]
    cmp al, '-'
    jne .check_first_digit
    inc rcx
    cmp rcx, [line_len]
    jae .none

.check_first_digit:
    mov al, [line_buf + rcx]
    cmp al, '0'
    jb .none
    cmp al, '9'
    ja .none

    mov [tok_ptr], rbx
    xor rax, rax
.digits:
    cmp rcx, [line_len]
    jae .done_digits
    mov dl, [line_buf + rcx]
    cmp dl, '0'
    jb .done_digits
    cmp dl, '9'
    ja .done_digits
    inc rcx
    jmp .digits

.done_digits:
    mov rax, rcx
    sub rax, rbx
    mov [tok_len], rax
    mov [parse_pos], rcx
    mov rax, 1
    pop rcx
    pop rbx
    ret

.none:
    xor eax, eax
    pop rcx
    pop rbx
    ret
