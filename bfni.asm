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
%define BUFFER_SIZE	4096

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
		.length: equ $-header
	times (BUFFER_SIZE - header.length) db 0

	;Footer for the compiled program
	footer:
		db `		mov eax, 1\n`
		db `		mov ebx, 0\n`
		db `		int 0x80\n`
		.length: equ $-footer

	;Compiled code for a single left shift of the tape
	shift_left:
		db `		dec si\n`
		.length: equ $-shift_left

	;Compiled code for a single right shift of the tape
	shift_right:
		db `		inc si\n`
		.length: equ $-shift_right

	;Compiled code for a shift in either direction of more than one unit;
	;This will be appended by a word parameter
	shift_long:
		db `		add si, `
		.length: equ $-shift_long

	;Compiled code for a decrement of the current tape value
	add_minus:
		db `		dec byte [tape + esi]\n`
		.length: equ $-add_minus

	;Compiled code for an increment of the current tape value
	add_plus:
		db `		inc byte [tape + esi]\n`
		.length: equ $-add_plus

	;Compiled code for an arbitrary addition/subtraction;
	;This will be appended with a byte parameter
	add_long:
		db `		add byte [tape + esi], `
		.length: equ $-add_long

	;Compiled code for a loop opening;
	;This will be appended with integer IDs for the end and beginning intervals
	loop_open:
		db `		cmp byte [tape + esi], 0\n`
		db `		je e`
		.length: equ $-loop_open

	;Compiled code for a loop closing;
	;This will be appended with integer IDs for the beginning and end intervals
	loop_close:
		db `		cmp byte [tape + esi], 0\n`
		db `		jne b`
		.length: equ $-loop_close

	;Compiled code for character input
	input:
		db `		call read_character\n`
		.length: equ $-input

	;Compiled code for character output
	output:
		db `		call write_character\n`
		.length: equ $-output

	;Error messages for input in which extraneous '[' or '] characters are present
	stray_open_message:
		db `;Error: unmatched '[' in input\n`
		.length: equ $-stray_open_message
	stray_close_message:
		db `\n;Error: unmatched ']' in input\n`
		.length: equ $-stray_close_message
section .text
	;Main
	_start:
		;Output buffer initially contains the header data
		mov edi, header.length


		;Zero out some important values
		xor ebx, ebx ;Loop counter
		mov edx, ebx ;Operation count
		push ebx ;Loop stack sentinel value

		;Read until EOF
		.input_loop:
			;Fill buffer
			call fill_input_buffer
			cmp eax, 0
			je .input_loop_break

			;Process input
			.process_loop:
				;Read in the current character
				mov dl, [ibuffer + esi]

				;Plus/minus and tape movement operations can fold into themselves,
				;and are thus compiled seperately in flush_last_op.
				;Plus/minus operations store their rolling count in cl (since they work with byte values);
				;tape movement ops work with words, therefore their count values are stored in cx

				cmp dl, '+'
				jne .not_plus
				.plus:
					;Check for repetition
					cmp dh, '+'
					je .pagain

					;Possibly flush the old operation
					call flush_last_op

					;Zero the counter
					mov dh, '+'
					xor ecx, ecx

					;Increment count
					.pagain:
						inc cl

					jmp .none
				.not_plus:

				;Note that is nearly symmetrical to op_plus
				cmp dl, '-'
				jne .not_minus
				.minus:
					;Check for repetition
					cmp dh, '+'
					je .magain

					;Possibly flush the old operation
					call flush_last_op

					;Zero the counter
					mov dh, '+'
					xor ecx, ecx

					;Decrement count
					.magain:
						dec cl

					jmp .none
				.not_minus:

				cmp dl, '>'
				jne .not_right
				.right:
					;Check for repitition
					cmp dh, '>'
					je .ragain

					;Possibly flush the old operation
					call flush_last_op

					;Zero the counter
					mov dh, '>'
					xor ecx, ecx

					;Note that tape movement operations store their count in the 16 bit cx register
					.ragain:
						inc cx

					jmp .none
				.not_right:

				cmp dl, '<'
				jne .not_left
				.left:
					cmp dh, '>'
					je .lagain

					call flush_last_op

					mov dh, '>'
					xor ecx, ecx

					.lagain:
						dec cx

					jmp .none
				.not_left:

				cmp dl, '.'
				jne .not_output
				.output:
					;Flush last op
					call flush_last_op

					;Write compiled code to buffer
					push esi
					;push ecx
					mov esi, output
					mov ecx, output.length
					call write_to_output
					;pop ecx
					pop esi
					jmp .none
				.not_output:

				cmp dl, ','
				jne .not_input
				.input:
					;Flush last op
					call flush_last_op

					;Write compiled code to buffer
					push esi
					;push ecx
					mov esi, input
					mov ecx, input.length
					call write_to_output
					;pop ecx
					pop esi
					jmp .none
				.not_input:

				cmp dl, '['
				jne .not_loop_open
				.loop_open:
					call flush_last_op

					push esi
					mov esi, loop_open
					mov ecx, loop_open.length
					call write_to_output
					pop esi

					inc ebx
					mov ecx, ebx
					call write_ecx_to_output

					cmp edi, BUFFER_SIZE - 4
					jl .ono_flush
					call flush_output_buffer
					.ono_flush:

					mov dword[obuffer + edi], `\n\t\tb`
					add edi, 4
					call write_ecx_to_output
					mov byte [obuffer + edi], ':'
					mov byte [obuffer + edi + 1], `\n`
					add edi, 2

					push ebx
					jmp .none
				.not_loop_open:

				cmp dl, ']'
				jne .not_loop_close
				.loop_close:
					call flush_last_op

					push esi
					mov esi, loop_close
					mov ecx, loop_close.length
					call write_to_output
					pop esi

					pop ecx

					cmp ecx, 0
					jne .loop_close_safe
						mov esi, stray_close_message
						mov ecx, stray_close_message.length
						call write_to_output
						jmp die_flush
					.loop_close_safe:
					call write_ecx_to_output

					cmp edi, BUFFER_SIZE - 4
					jl .cno_flush
					call flush_output_buffer
					.cno_flush:

					mov dword[obuffer + edi], `\n\t\te`
					add edi, 4
					call write_ecx_to_output
					mov byte [obuffer + edi], ':'
					mov byte [obuffer + edi + 1], `\n`
					add edi, 2

					jmp .none
				.not_loop_close:

				.none:

				inc esi
				cmp esi, eax
				jl .process_loop

			jmp .input_loop
		.input_loop_break:

		call flush_last_op

		pop ecx
		cmp ecx, 0
		je .loop_open_safe
			mov esi, stray_open_message
			mov ecx, stray_open_message.length
			call write_to_output
			jmp die_flush
		.loop_open_safe:

		mov esi, footer
		mov ecx, footer.length
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
			mov ecx, add_long.length
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
				mov ecx, add_plus.length
				mov esi, add_plus
				call write_to_output
				jmp write_current_op_return
			compile_add_dec:
				mov ecx, add_minus.length
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
			mov ecx, shift_long.length
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
				mov ecx, shift_right.length
				mov esi, shift_right
				call write_to_output
				jmp write_current_op_return
			compile_shift_left:
				mov ecx, shift_left.length
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
