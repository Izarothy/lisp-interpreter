%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_EXIT 60

%define STDIN 0
%define STDOUT 1

%define LINE_BUF_SIZE 4096

%define OP_ADD 1
%define OP_SUB 2
%define OP_MUL 3

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

    call parse_line_eval
    ; Evaluation stage: result printing and mapped errors added later.
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

; parse_line_eval -> rdx=1 success (rax=value), rdx=0 failure
parse_line_eval:
    call skip_ws
    call parse_expr_eval
    cmp rdx, 1
    jne .done
    call skip_ws
    mov rcx, [parse_pos]
    cmp rcx, [line_len]
    jne .fail
.done:
    ret
.fail:
    xor edx, edx
    ret

; parse_expr_eval -> rdx=1 success (rax=value), rdx=0 failure
parse_expr_eval:
    call skip_ws
    call peek_char
    cmp al, '('
    je .list

    call read_number_token
    cmp rax, 1
    jne .fail
    call parse_number_from_token
    mov edx, 1
    ret

.list:
    jmp parse_list_eval

.fail:
    xor eax, eax
    xor edx, edx
    ret

; parse_list_eval -> rdx=1 success (rax=value), rdx=0 failure
parse_list_eval:
    push rbx
    push rcx
    push r8
    push r9
    push r10

    call peek_char
    cmp al, '('
    jne .fail
    call advance_char

    call skip_ws
    call peek_char
    cmp al, 0
    je .fail
    cmp al, ')'
    je .fail

    mov rbx, [parse_pos]
    call read_symbol_token
    cmp rax, 1
    je .symbol_form

    mov [parse_pos], rbx
    call read_number_token
    cmp rax, 1
    jne .fail
    call parse_number_from_token
    mov r8, rax
    call skip_ws
    call peek_char
    cmp al, ')'
    jne .fail
    call advance_char
    mov rax, r8
    mov edx, 1
    jmp .ok

.symbol_form:
    call parse_op_token
    cmp eax, 0
    je .fail
    mov r9, rax          ; op code

    xor rcx, rcx         ; arg count
    xor r8, r8           ; accumulator

.arg_loop:
    call skip_ws
    call peek_char
    cmp al, 0
    je .fail
    cmp al, ')'
    je .close

    call parse_expr_eval
    cmp rdx, 1
    jne .fail

    cmp rcx, 0
    jne .combine
    mov r8, rax
    inc rcx
    jmp .arg_loop

.combine:
    cmp r9, OP_ADD
    je .combine_add
    cmp r9, OP_SUB
    je .combine_sub
    cmp r9, OP_MUL
    je .combine_mul
    jmp .fail

.combine_add:
    add r8, rax
    inc rcx
    jmp .arg_loop

.combine_sub:
    sub r8, rax
    inc rcx
    jmp .arg_loop

.combine_mul:
    imul r8, rax
    inc rcx
    jmp .arg_loop

.close:
    cmp rcx, 0
    je .fail
    call advance_char

    cmp r9, OP_SUB
    jne .return_acc
    cmp rcx, 1
    jne .return_acc
    neg r8

.return_acc:
    mov rax, r8
    mov edx, 1
    jmp .ok

.fail:
    xor eax, eax
    xor edx, edx

.ok:
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

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

; parse tok_ptr/tok_len as decimal signed integer -> rax
parse_number_from_token:
    push rbx
    push rcx
    push rdx
    push rsi

    mov rsi, [tok_ptr]
    mov rcx, [tok_len]
    lea rsi, [line_buf + rsi]
    xor rax, rax
    xor rbx, rbx

    cmp rcx, 0
    je .done

    mov dl, [rsi]
    cmp dl, '-'
    jne .digits
    mov bl, 1
    inc rsi
    dec rcx

.digits:
    cmp rcx, 0
    je .apply_sign
    movzx rdx, byte [rsi]
    sub rdx, '0'
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    dec rcx
    jmp .digits

.apply_sign:
    cmp bl, 1
    jne .done
    neg rax

.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; parse operator token in tok_ptr/tok_len -> eax opcode or 0
parse_op_token:
    mov rcx, [tok_ptr]
    lea rsi, [line_buf + rcx]
    mov rcx, [tok_len]

    cmp rcx, 3
    je .len3
    cmp rcx, 4
    je .len4
    xor eax, eax
    ret

.len3:
    mov al, [rsi]
    cmp al, 'a'
    jne .check_sub_mul
    cmp byte [rsi + 1], 'd'
    jne .unknown
    cmp byte [rsi + 2], 'd'
    jne .unknown
    mov eax, OP_ADD
    ret

.check_sub_mul:
    cmp al, 's'
    jne .check_mul
    cmp byte [rsi + 1], 'u'
    jne .unknown
    cmp byte [rsi + 2], 'b'
    jne .unknown
    mov eax, OP_SUB
    ret

.check_mul:
    cmp al, 'm'
    jne .unknown
    cmp byte [rsi + 1], 'u'
    jne .unknown
    cmp byte [rsi + 2], 'l'
    jne .unknown
    mov eax, OP_MUL
    ret

.len4:
    ; div handled in later arithmetic commit
    xor eax, eax
    ret

.unknown:
    xor eax, eax
    ret
