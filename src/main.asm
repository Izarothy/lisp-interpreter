default rel

global _start

section .text
_start:
    xor edi, edi
    mov eax, 60
    syscall