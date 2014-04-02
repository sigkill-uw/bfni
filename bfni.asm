;bfni is BrainFuck - but Not Interpreted
;Author: sigkill (Adam)
;Usage:
;Pipe a BrainFuck program into the standard input.
;An equivalent NASM x86 assembly program will be delivered via standard output.
;The resultant code has a tape length of exactly 65356.

;Compiled code can be built with the following process:
;bfni < source.bf > program.asm
;nasm -f elf program.asm
;ld -m elf_i386 -o program program.o

;Conventions used within compiler code:
;eax: input buffer length
;esi: input buffer index
;edi: output buffer index
;ebx: loop index
;dh:  current opcode
;dl:  currently-parsed character
;cx:  count for currently-buffer opcode
;ecx: character count for write function

;*nix syscall interrupts
%define SYS_EXIT	1
%define SYS_READ	3
%define SYS_WRITE	4

;Streams
%define STDIN		0
%define STDOUT		1

;Input and output buffer sizes
%define BUFFER_SIZE	512

global _start

section .bss
	;Input buffer is empty
	ibuffer: resb BUFFER_SIZE

section .data
	;For conversions to hexadecimal
	hex_table: db '0123456789ABCDEF'

	;We can initialize the output buffer with the code header
	obuffer:
	header:
		db `global _start\n`
		db `section .data\n`
		db `	tape: times 0x10000 db 0x00\n`
		db `section .text\n`
		db `	read_character:\n`
		db `		mov eax, 3\n`
		db `		mov ebx, 0\n`
		db `		lea ecx, [tape + esi]\n`
		db `		mov edx, 1\n`
		db `		int 0x80\n`
		db `		ret\n`
		db `	write_character:\n`
		db `		mov eax, 4\n`
		db `		mov ebx, 1\n`
		db `		lea ecx, [tape + esi]\n`
		db `		mov edx, 1\n`
		db `		int 0x80\n`
		db `		ret\n`
		db `	_start:\n`
		db `		xor esi, esi\n`
	header_length: equ $-header
	times (BUFFER_SIZE - header_length) db 0

	footer:
		db `		mov eax, 1\n`
		db `		mov ebx, 0\n`
		db `		int 0x80\n`
	footer_length: equ $-footer

	;Compiled code for a single left shift of the tape
	shift_left:
		db `		dec si\n`
	shift_left_length: equ $-shift_left

	;Compiled code for a single right shift of the tape
	shift_right:
		db `		inc si\n`
	shift_right_length: equ $-shift_right

	;Compiled code for a single shift in either direction of more than one unit
	shift_long:
		db `		add si, `
	shift_long_length: equ $-shift_long

	;Compiled code for a decrement of the current tape value
	add_minus:
		db `		dec byte [tape + esi]\n`
	add_minus_length: equ $-add_minus

	;Compiled code for an increment of the current tape value
	add_plus:
		db `		inc byte [tape + esi]\n`
	add_plus_length: equ $-add_plus

	;Compiled code for an arbitrary addition/subtraction
	add_long:
		db `		add byte [tape + esi], `
	add_long_length: equ $-add_long

	;Compiled code for a loop opening
	loop_open:
		db `		cmp byte [tape + esi], 0\n`
		db `		je e`
	loop_open_length: equ $-loop_open

	;Compiled code for a loop closing
	loop_close:
		db `		cmp byte [tape + esi], 0\n`
		db `		jne b`
	loop_close_length: equ $-loop_close

	;Compiled code for character input
	input:
		db `		call read_character\n`
	input_length: equ $-input

	;Compiled code for character output
	output:
		db `		call write_character\n`
	output_length: equ $-output
section .text
	;Main
	_start:
		;Output buffer initially contains the header data
		mov edi, header_length

		;Zero is a sentinel value for our loop stack. Also zero out the counter.
		push 0
		xor ebx, ebx

		;Null opcode
		xor edx, edx

		;Read until EOF
		input_loop:
			;Fill buffer
			call fill_input_buffer
			cmp eax, 0
			je input_loop_break

			;Process input
			process_loop:
				;Read in the current character
				mov dl, [ibuffer + esi]

				;Basically a big switch

				cmp dl, '+'
				je op_plus
				cmp dl, '-'
				je op_minus

				cmp dl, '>'
				je op_right
				cmp dl, '<'
				je op_left

				cmp dl, '.'
				je op_output
				cmp dl, ','
				je op_input

				cmp dl, '['
				je op_loop_open
				cmp dl, ']'
				je op_loop_close

				;Default
				jmp op_none

				;Plus/minus and tape movement operations can fold into themselves,
				;and are thus compiled seperately in flush_last_op.
				;Plus/minus operations store their rolling count in cl (since they work with byte values);
				;tape movement ops work with words, therefore their count values are stored in cx

				;Plus/minus operations store their count
				op_plus:
					;Check for repetition
					cmp dh, '+'
					je op_plus_again

					;Possibly flush the old operation
					call flush_last_op

					;Zero the counter
					mov dh, '+'
					xor ecx, ecx

					;Increment count
					op_plus_again:
						inc cl

					jmp op_none

				;Note that op_minus is nearly symmetrical to op_plus
				op_minus:
					;Check for repetition
					cmp dh, '+'
					je op_minus_again

					;Possibly flush the old operation
					call flush_last_op

					;Zero the counter
					mov dh, '+'
					xor ecx, ecx

					;Decrement count
					op_minus_again:
						dec cl

					jmp op_none

				;op_right and op_left are analgous to op_plus and op_mins
				op_right:
					;Check for repitition
					cmp dh, '>'
					je op_right_again

					;Possibly flush the old operation
					call flush_last_op

					;Zero the counter
					mov dh, '>'
					xor ecx, ecx

					;Note that tape movement operations store their count in the 16 bit cx register
					op_right_again:
						inc cx

					jmp op_none

				;Inverse of op_right
				op_left:
					cmp dh, '>'
					je op_left_again

					call flush_last_op

					mov dh, '>'
					xor ecx, ecx

					op_left_again:
						dec cx

					jmp op_none

				;Input and output compilation is just a simple string output, so it's simple to handle them here
				;I'm pretty sure pushing/popping ecx isn't necessary, since it's only used in the context of move/add ops
				op_output:
					;Flush last op
					call flush_last_op

					;Write compiled code to buffer
					push esi
					;push ecx
					mov esi, output
					mov ecx, output_length
					call write_to_output
					;pop ecx
					pop esi
					jmp op_none

				op_input:
					;Flush last op
					call flush_last_op

					;Write compiled code to buffer
					push esi
					;push ecx
					mov esi, input
					mov ecx, input_length
					call write_to_output
					;pop ecx
					pop esi
					jmp op_none

				op_loop_open:
					call flush_last_op

					push esi
					mov esi, loop_open
					mov ecx, loop_open_length
					call write_to_output
					pop esi

					inc ebx
					mov ecx, ebx
					call write_ecx_to_output

					cmp edi, BUFFER_SIZE - 4
					jl .no_flush
					call flush_output_buffer
					.no_flush:

					mov dword[obuffer + edi], `\n\t\tb`
					add edi, 4
					call write_ecx_to_output
					mov byte [obuffer + edi], ':'
					mov byte [obuffer + edi + 1], `\n`
					add edi, 2

					push ebx
					jmp op_none

				op_loop_close:
					call flush_last_op

					push esi
					mov esi, loop_close
					mov ecx, loop_close_length
					call write_to_output
					pop esi

					pop ecx
					call write_ecx_to_output

					cmp edi, BUFFER_SIZE - 4
					jl .no_flush
					call flush_output_buffer
					.no_flush:

					mov dword[obuffer + edi], `\n\t\te`
					add edi, 4
					call write_ecx_to_output
					mov byte [obuffer + edi], ':'
					mov byte [obuffer + edi + 1], `\n`
					add edi, 2

					jmp op_none

				op_none:

				inc esi
				cmp esi, eax
				jl process_loop

			jmp input_loop
		input_loop_break:

		call flush_last_op

		mov ecx, footer_length
		mov esi, footer
		call write_to_output

		call flush_output_buffer

	;Quit routine
	quit:
		mov eax, SYS_EXIT
		xor ebx, ebx
		int 0x80

	;Quit and flush the output
	die_flush:
		call flush_output_buffer
	;Just quit with error
	die:
		mov eax, SYS_EXIT
		mov ebx, 1
		int 0x80

	;Routine to fill the input buffer from stdin
	fill_input_buffer:
		;Prrrretty sure these are the only registers that need to be pushed
		push ebx
		push ecx
		push edx

		;Read new data into the buffer
		mov eax, SYS_READ
		;mov ebx, STDIN
		xor ebx, ebx
		mov ecx, ibuffer
		mov edx, BUFFER_SIZE
		int 0x80

		;Die on input error (but 0 bytes read isn't an error)
		cmp eax, 0
		jl die

		;Reset the buffer index
		xor esi, esi

		pop edx
		pop ecx
		pop ebx

		;We now have a buffer length in eax, and a zeroed index into the buffer in esi
		ret

	;Routine to write data to output buffer, possibly flushing along the way
	write_to_output:
		;Check if we need to flush
		add edi, ecx
		cmp edi, BUFFER_SIZE
		jl no_flush

		;Flush

		;sub has to be after the jl, because otherwise we'll destroy the relevant flags
		sub edi, ecx

		call flush_output_buffer

		jmp flushed

		no_flush:
			sub edi, ecx
		flushed:

		;This code is BROKEN for large inputs (larger than the buffer size.)
		;This SHOULD be a bug at best and an exploitable hole at worst,
		;but the longest input will be a few hundred chars and no input is coming from an external source.
		;Keep the buffer size reasonable.

		;Gotta use an absolute address for movsb
		add edi, obuffer

		;ecx should contain the length of the byte buffer to copy;
		;esi should contain the source.

		;Copy (is it maybe worth it to copy as words/dwords instead? Probably not.)
		rep movsb

		;Reset edi to "index mode"
		sub edi, obuffer

		ret

	;Routine to write any buffered data to stdout, based on index in edi
	flush_output_buffer:
		push eax
		push ebx
		push ecx
		push edx

		;Write data from output buffer
		mov eax, SYS_WRITE
		mov ebx, STDOUT
		mov ecx, obuffer,
		mov edx, edi
		int 0x80

		;Die on output error (if we don't write everything, it's an error)
		cmp eax, edi
		jl die

		;Reset the buffer index
		xor edi, edi

		pop edx
		pop ecx
		pop ebx
		pop eax

		ret

	;Routine to output the compiled code for the given operator in dh and ecx
	flush_last_op:
		;Ignore null ops
		cmp ecx, 0
		jne flush_last_op_good

		ret

		flush_last_op_good:

		;Push the registers that we'll be munging with
		push esi
		;push ecx ;This isn't actually necessary, since ecx has no significance when dh is 0

		;Switch
		cmp dh, '+'
		je compile_add
		cmp dh, '>'
		je compile_shift

		;Nop
		jmp write_current_op_return

		;Addition/subtraction
		;Convention note: since this is an 8 bit operation, the 'count' field is cl;
		;thus we shouldn't have to do any witchcraft for negative values
		compile_add:
			;Special cases for movements by one cell
			cmp cl, 1
			je compile_add_inc
			cmp cl, -1
			je compile_add_dec

			;General case

			;Gonna need this later
			push ecx

			;Copy the header for the operation
			mov ecx, add_long_length
			mov esi, add_long
			call write_to_output
			mov esi, [esp + 4 * 1] ;Restore input pointer

			;We need a few bytes in the output buffer to output the relevant integer:
			;`0xNN\n` -> 5 bytes

			cmp edi, BUFFER_SIZE - 5
			jl compile_add_no_flush

			call flush_output_buffer
			compile_add_no_flush:
				;0x
				mov byte [obuffer + edi], '0'
				mov byte [obuffer + edi + 1], 'x'

				;High-order nybble
				mov ecx, [esp]
				shr ecx, 4
				and ecx, 0x0F
				mov ch, [hex_table + ecx]
				mov byte [obuffer + edi + 2], ch

				;Low-order nybble
				mov ecx, [esp]
				and ecx, 0x0F
				mov ch, [hex_table + ecx]
				mov byte [obuffer + edi + 3], ch

				;Newline
				mov byte [obuffer + edi + 4], `\n`

				;Shift index
				add edi, 5

			pop ecx
			jmp write_current_op_return

			;Increments/decrements are basically just string copies
			compile_add_inc:
				mov ecx, add_plus_length
				mov esi, add_plus
				call write_to_output
				jmp write_current_op_return
			compile_add_dec:
				mov ecx, add_minus_length
				mov esi, add_minus
				call write_to_output
				jmp write_current_op_return

		compile_shift:
			;Special cases for short shifts
			cmp cx, 1
			je compile_shift_right
			cmp cx, -1
			je compile_shift_left

			;General case
			push ecx ;Gonna need this later, again

			;Copy the header for the operation
			mov ecx, shift_long_length
			mov esi, shift_long
			call write_to_output
			mov esi, [esp + 4 * 1] ;Restore input pointer

			;We need a few more bytes to print the offset for this
			;`0xNNNN\n` -> 7 bytes

			cmp edi, BUFFER_SIZE - 7
			jl compile_shift_no_flush

			call flush_output_buffer
			compile_shift_no_flush:
				;0x
				mov byte [obuffer + edi], '0'
				mov byte [obuffer + edi + 1], 'x'

				;High-order nybble of high-order byte
				mov ecx, [esp]
				shr ecx, 12
				and ecx, 0x0F
				mov ch, [hex_table + ecx]
				mov byte [obuffer + edi + 2], ch

				;Low-order nybble of high-order byte
				mov ecx, [esp]
				shr ecx, 8
				and ecx, 0x0F
				mov ch, [hex_table + ecx]
				mov byte [obuffer + edi + 3], ch

				;High-order nybble of low-order byte
				mov ecx, [esp]
				shr ecx, 4
				and ecx, 0x0F
				mov ch, [hex_table + ecx]
				mov byte [obuffer + edi + 4], ch

				;Low-order nybble of lower-order byte
				mov ecx, [esp]
				and ecx, 0x0F
				mov ch, [hex_table + ecx]
				mov byte [obuffer + edi + 5], ch

				;Newline
				mov byte [obuffer + edi + 6], `\n`

				;Shift index
				add edi, 7

			pop ecx
			jmp write_current_op_return

			;Special cases
			compile_shift_right:
				mov ecx, shift_right_length
				mov esi, shift_right
				call write_to_output
				jmp write_current_op_return
			compile_shift_left:
				mov ecx, shift_left_length
				mov esi, shift_left
				call write_to_output
				jmp write_current_op_return

			jmp write_current_op_return

		write_current_op_return:
			xor dh, dh
			pop esi
			ret

	write_ecx_to_output:
		push ecx

		;`NNNNNNNN` -> 8 bytes required,
		;but we'll flush sooner than that since we're sticking up to 2 characters on the end
		cmp edi, BUFFER_SIZE - 10
		jl .no_flush

		call flush_output_buffer

		.no_flush:
			;No 0x since this is going to be used with labels
			;Massive unrolled loop below

			;Nnnnnnnn
			mov ecx, [esp]
			shr ecx, 28
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 0], ch

			;0xnNnnnnnn
			mov ecx, [esp]
			shr ecx, 24
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 1], ch

			;0xnnNnnnnn
			mov ecx, [esp]
			shr ecx, 20
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 2], ch

			;nnnNnnnn
			mov ecx, [esp]
			shr ecx, 16
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 3], ch

			;nnnnNnnn
			mov ecx, [esp]
			shr ecx, 12
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 4], ch

			;nnnnnNnn
			mov ecx, [esp]
			shr ecx, 8
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 5], ch

			;nnnnnnNn
			mov ecx, [esp]
			shr ecx, 4
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 6], ch

			;nnnnnnnN
			mov ecx, [esp]
			;shr ecx, 0
			and ecx, 0x0F
			mov ch, [hex_table + ecx]
			mov byte [obuffer + edi + 7], ch

			add edi, 8

		pop ecx
		ret
