# Weird that awk does not come with abs(), so I need to implement it.
function abs(x) {
	return ( (x < 0) ? -x : x )
}

# Ditto for ceiling function.
function ceil(x) {
	return (x == int(x)) ? x : int(x) + 1
}

# Local variables MUST be declared in argument list, else they are
# seen as global. Ugly, but that is how awk works.
function get_terminal_size(SIZE, SIZEA, HAS_DETECTED, CMD) {
	HAS_DETECTED = 0

	CMD = "stty -f /dev/tty size 2> /dev/null"

	if ( (CMD | getline SIZE) == 1 ) {
		split(SIZE, SIZEA, " ")
		LINES   = int(SIZEA[1])
		COLUMNS = int(SIZEA[2])
		HAS_DETECTED = 1
	}
	close(CMD)

	if ( HAS_DETECTED == 0 ) {
		CMD = "tput lines"
		if ( (CMD | getline SIZE) == 1 ) {
			LINES = int(SIZE)
			HAS_DETECTED = 1
		}
		close(CMD)

		CMD = "tput cols"
		if ( (CMD | getline SIZE) == 1 ) {
			COLUMNS = int(SIZE)
			HAS_DETECTED = 1
		}
		close(CMD)
	}

	if ( int('"${OVERRIDE_COLUMNS}"') ) { COLUMNS = int('"${OVERRIDE_COLUMNS}"') }
	if ( int('"${OVERRIDE_LINES}"')   ) { LINES   = int('"${OVERRIDE_LINES}"')   }
}

############################################################
# Functions related to cursor handling

# Function called whenever a non-dotted line is printed.
#
# It will move the cursor to the line next to the statistics and
# restore the default color.
function other_line_is_printed() {
	if ( IS_PRINTING_DOTS ) {
		if ( '"${IS_TERMINAL}"' ) {
			printf( ESC_DEFAULT ESC_NEXTLINE ESC_NEXTLINE "\n" )
		} else {
			printf( ESC_DEFAULT "\n" )
			print_statistics_bar()
		}
	}
	IS_PRINTING_DOTS = 0
	CURR_COL = 0
}

# Function called whenever a non-dotted line is repeated.
function other_line_is_repeated() {
	if ( other_line_times < 2 ) {
		return
	}
	if ( '"${IS_TERMINAL}"' ) {
		printf( ESC_DEFAULT ESC_ERASELINE "\r" )
	}
	printf( "Last message repeated %d times.", other_line_times )
	if ( ! '"${IS_TERMINAL}"' ) {
		printf( "\n" )
	}
}

# Function called whenever the repeating line has changed.
function other_line_finished_repeating() {
	if ( other_line_times >= 2 ) {
		if ( '"${IS_TERMINAL}"' ) {
			printf( "\n" )
		} else {
			other_line_is_repeated()
		}
	}
	other_line = ""
	other_line_times = 0
}

# Prints the newlines required for the live statistics.
#
# I need to print some newlines and then return the cursor back to its position
# to make sure the terminal will scroll.
#
# If the output is not a terminal, break lines on every LAST_N dots.
function print_newlines_if_needed() {
	if ( '"${IS_TERMINAL}"' ) {
		# COLUMNS-1 because I want to avoid bugs with the cursor at the last column
		if ( CURR_COL >= COLUMNS-1 ) {
			CURR_COL = 0
		}
		if ( CURR_COL == 0 ) {
			if ( IS_PRINTING_DOTS ) {
				printf( "\n" )
			}
			#printf( "\n" "\n" ESC_PREVLINE ESC_PREVLINE ESC_ERASELINE )
			printf( ESC_DEFAULT "\n" "\n" ESC_CURSORUP ESC_CURSORUP ESC_ERASELINE )
		}
	} else {
		if ( CURR_COL >= LAST_N ) {
			CURR_COL = 0
			printf( ESC_DEFAULT "\n" )
			print_statistics_bar()
		}
	}
	IS_PRINTING_DOTS = 1
}

############################################################
# Functions related to the data structure of "Last N" statistics.

# Clears the data structure.
function clear(d) {
	d["index"] = 0  # The next position to store a value
	d["size"]  = 0  # The array size, goes up to LAST_N
}

# This function stores the value to the passed data structure.
# The data structure holds at most LAST_N values. When it is full,
# a new value overwrite the oldest one.
function store(d, value) {
	d[d["index"]] = value
	d["index"]++
	if ( d["index"] >= d["size"] ) {
		if ( d["size"] < LAST_N ) {
			d["size"]++
		} else {
			d["index"] = 0
		}
	}
}

############################################################
# Functions related to processing the received response

function process_rtt(rtt) {
	# Overall statistics
	last_rtt = rtt
	total_rtt += rtt
	if ( last_seq == 0 ) {
		min_rtt = max_rtt = rtt
	} else {
		if ( rtt < min_rtt ) min_rtt = rtt
		if ( rtt > max_rtt ) max_rtt = rtt
	}

	# "Last N" statistics
	store(lastn_rtt,rtt)
}

function lost_a_packet() {
	print_newlines_if_needed()
	print_missing_response()

	last_seq++
	lost++
	store(lastn_lost, 1)
}

############################################################
# Functions related to printing the fancy ping response

# block_index, n, w are just local variables.
function print_response_legend(i, n, w) {
	if ( ! '"${USE_LEGEND}"' ) {
		return
	}
	if ( BLOCK_LEN > 1 ) {
		# w counts the cursor position in the current line. Because of the
		# escape codes, I need to jump through some hoops in order to count the
		# position correctly.
		w = 0
		n = "0 "
		w += length(n) + 1

		printf( n BLOCK[0] ESC_DEFAULT )

		for ( i=1 ; i<BLOCK_LEN ; i++ ) {
			n = sprintf( "%d ", BLOCK_RTT_MIN + ceil((i-1) * BLOCK_RTT_RANGE / (BLOCK_LEN - 2)) )
			w += length(n) + 1

			# Avoid breaking the legend at the end of the line.
			# Also avoids a background color change right at
			# the edge of the screen. (If it happens, the entire next line
			# will have that background color, which is not desired.)
			if ( '"${IS_TERMINAL}"' && w + 1 >= COLUMNS ) {
				printf( "\n" )
				w = length(n) + 1
			} else {
				printf( " " )
				w += 1
			}

			printf( n BLOCK[i] ESC_DEFAULT )
		}
		printf( " ∞\n" )
	}

	# Useful code for debugging.
	#for ( i=0 ; i<=BLOCK_RTT_MAX ; i++ ) {
	#	print_received_response(i)
	#	printf( ESC_DEFAULT "%4d\n", i )
	#}
}

# block_index is just a local variable.
function print_received_response(rtt, block_index) {
	if ( rtt < BLOCK_RTT_MIN ) {
		block_index = 0
	} else if ( rtt >= BLOCK_RTT_MAX ) {
		block_index = BLOCK_LEN - 1
	} else {
		block_index = 1 + int((rtt - BLOCK_RTT_MIN) * (BLOCK_LEN - 2) / BLOCK_RTT_RANGE)
	}
	printf( BLOCK[block_index] )
	CURR_COL++
}

function print_missing_response(rtt) {
	printf( ESC_RED "!" )
	CURR_COL++
}

############################################################
# Functions related to printing statistics

# All arguments are just local variables.
function print_overall(percentage_lost, avg_rtt) {
	# Handling division by zero.
	# Note that mawk does not consider division by zero an error, while all
	# other awk implementations abort in such case.
	# https://stackoverflow.com/questions/14581966/why-does-awk-produce-different-results-for-division-by-zero

	avg_rtt = ( received > 0 ) ? (total_rtt/received) : 0
	percentage_lost = ( lost+received > 0 ) ? (lost*100/(lost+received)) : 0

	if ( '"${IS_TERMINAL}"' ) {
		printf( "%2d/%3d (%2d%%) lost; %4.0f/" ESC_BOLD "%4.0f" ESC_DEFAULT "/%4.0fms; last: " ESC_BOLD "%4.0f" ESC_DEFAULT "ms",
			lost,
			lost+received,
			percentage_lost,
			min_rtt,
			avg_rtt,
			max_rtt,
			last_rtt )
	} else {
		printf( "%2d/%3d (%2d%%) lost; %4.0f/" ESC_BOLD "%4.0f" ESC_DEFAULT "/%4.0fms",
			lost,
			lost+received,
			percentage_lost,
			min_rtt,
			avg_rtt,
			max_rtt )
	}
}

# All arguments are just local variables.
function print_last_n(i, percentage_lost, sum, min, avg, max, diffs) {
	# Calculate and print the lost packets statistics
	sum = 0
	for ( i=0 ; i<lastn_lost["size"] ; i++ ) {
		sum += lastn_lost[i]
	}
	percentage_lost = (lastn_lost["size"] > 0) ? (sum*100/lastn_lost["size"]) : 0
	printf( "%2d/%3d (%2d%%) lost; ",
		sum,
		lastn_lost["size"],
		percentage_lost )

	# Calculate the min/avg/max rtt times
	sum = diffs = 0
	min = max = lastn_rtt[0]
	for ( i=0 ; i<lastn_rtt["size"] ; i++ ) {
		sum += lastn_rtt[i]
		if ( lastn_rtt[i] < min ) min = lastn_rtt[i]
		if ( lastn_rtt[i] > max ) max = lastn_rtt[i]
	}
	avg = (lastn_rtt["size"]) ? (sum/lastn_rtt["size"]) : 0

	# Calculate mdev (mean absolute deviation)
	for ( i=0 ; i<lastn_rtt["size"] ; i++ ) {
		diffs += abs(lastn_rtt[i] - avg)
	}
	if ( lastn_rtt["size"] > 0 ) {
		diffs /= lastn_rtt["size"]
	}

	# Print the rtt statistics
	printf( "%4.0f/" ESC_BOLD "%4.0f" ESC_DEFAULT "/%4.0f/%4.0fms (last %d)",
		min,
		avg,
		max,
		diffs,
		lastn_rtt["size"] )
}

function print_statistics_bar() {
	if ( '"${IS_TERMINAL}"' ) {
		printf( ESC_SAVEPOS ESC_DEFAULT )

		printf( ESC_NEXTLINE ESC_ERASELINE )
		print_overall()
		printf( ESC_NEXTLINE ESC_ERASELINE )
		print_last_n()

		printf( ESC_UNSAVEPOS )
	} else {
		print_overall()
		printf( "\n" )
		print_last_n()
		printf( "\n" )
	}
}

function print_statistics_bar_if_terminal() {
	if ( '"${IS_TERMINAL}"' ) {
		print_statistics_bar()
	}
}

############################################################
# Initializations
BEGIN {
	# Easy way to get each value from ping output
	FS = "="

	############################################################
	# General internal variables

	# This is needed to keep track of lost packets
	last_seq = 0

	# The previously printed non-ping-response line
	other_line = ""
	other_line_times = 0

	# Variables to keep the screen clean
	IS_PRINTING_DOTS = 0
	CURR_COL = 0

	############################################################
	# Variables related to "overall" statistics
	received = 0
	lost = 0
	total_rtt = 0
	min_rtt = 0
	max_rtt = 0
	last_rtt = 0

	############################################################
	# Variables related to "last N" statistics
	LAST_N = int('"${LAST_N}"')

	# Data structures for the "last N" statistics
	clear(lastn_lost)
	clear(lastn_rtt)

	############################################################
	# Terminal height and width

	# These are sane defaults, in case we cannot query the actual terminal size
	LINES    = 24
	COLUMNS  = 80

	# Auto-detecting the terminal size
	get_terminal_size()
	if ( '"${IS_TERMINAL}"' && COLUMNS <= 50 ) {
		print "Warning: terminal width is too small."
	}

	############################################################
	# ANSI escape codes

	# Color escape codes.
	# Fortunately, awk defaults any unassigned variable to an empty string.
	if ( '"${USE_COLOR}"' ) {
		ESC_DEFAULT = "\033[0m"
		ESC_BOLD    = "\033[1m"
		#ESC_BLACK   = "\033[0;30m"
		#ESC_GRAY    = "\033[1;30m"
		ESC_RED     = "\033[0;31m"
		ESC_GREEN   = "\033[0;32m"
		ESC_YELLOW  = "\033[0;33m"
		ESC_BLUE    = "\033[0;34m"
		ESC_MAGENTA = "\033[0;35m"
		ESC_CYAN    = "\033[0;36m"
		ESC_WHITE   = "\033[0;37m"
		ESC_YELLOW_ON_GREEN = "\033[42;33m"
		ESC_RED_ON_YELLOW   = "\033[43;31m"
	}
	# Other escape codes, see:
	# http://en.wikipedia.org/wiki/ANSI_escape_code
	# http://invisible-island.net/xterm/ctlseqs/ctlseqs.html
	ESC_NEXTLINE     = "\n"
	ESC_CURSORUP     = "\033[A"
	ESC_CURSORDOWN   = "\033[B"
	ESC_SCROLLUP     = "\033[S"
	ESC_SCROLLDOWN   = "\033[T"
	ESC_ERASELINEEND = "\033[0K"
	ESC_ERASELINE    = "\033[2K"
	ESC_SAVEPOS      = "\0337"
	ESC_UNSAVEPOS    = "\0338"

	# I am avoiding these escapes as they are not listed in:
	# http://vt100.net/docs/vt100-ug/chapter3.html
	#ESC_PREVLINE   = "\033[F"
	#ESC_SAVEPOS    = "\033[s"
	#ESC_UNSAVEPOS  = "\033[u"

	# I am avoiding this to improve compatibility with (older versions of) tmux
	#ESC_NEXTLINE   = "\033[E"

	############################################################
	# Unicode characters (based on https://github.com/holman/spark )
	if ( '"${USE_UNICODE}"' ) {
		BLOCK[ 0] = ESC_GREEN "▁"
		BLOCK[ 1] = ESC_GREEN "▂"
		BLOCK[ 2] = ESC_GREEN "▃"
		BLOCK[ 3] = ESC_GREEN "▄"
		BLOCK[ 4] = ESC_GREEN "▅"
		BLOCK[ 5] = ESC_GREEN "▆"
		BLOCK[ 6] = ESC_GREEN "▇"
		BLOCK[ 7] = ESC_GREEN "█"
		BLOCK[ 8] = ESC_YELLOW_ON_GREEN "▁"
		BLOCK[ 9] = ESC_YELLOW_ON_GREEN "▂"
		BLOCK[10] = ESC_YELLOW_ON_GREEN "▃"
		BLOCK[11] = ESC_YELLOW_ON_GREEN "▄"
		BLOCK[12] = ESC_YELLOW_ON_GREEN "▅"
		BLOCK[13] = ESC_YELLOW_ON_GREEN "▆"
		BLOCK[14] = ESC_YELLOW_ON_GREEN "▇"
		BLOCK[15] = ESC_YELLOW_ON_GREEN "█"
		BLOCK[16] = ESC_RED_ON_YELLOW "▁"
		BLOCK[17] = ESC_RED_ON_YELLOW "▂"
		BLOCK[18] = ESC_RED_ON_YELLOW "▃"
		BLOCK[19] = ESC_RED_ON_YELLOW "▄"
		BLOCK[20] = ESC_RED_ON_YELLOW "▅"
		BLOCK[21] = ESC_RED_ON_YELLOW "▆"
		BLOCK[22] = ESC_RED_ON_YELLOW "▇"
		BLOCK[23] = ESC_RED_ON_YELLOW "█"
		if ( '"${USE_MULTICOLOR}"' && '"${USE_COLOR}"' ) {
			# Multi-color version:
			BLOCK_LEN = 24
			BLOCK_RTT_MIN = 10
			BLOCK_RTT_MAX = 230
		} else {
			# Simple version:
			BLOCK_LEN = 8
			BLOCK_RTT_MIN = 25
			BLOCK_RTT_MAX = 175
		}
	} else {
		BLOCK[ 0] = ESC_GREEN "_"
		BLOCK[ 1] = ESC_GREEN "."
		BLOCK[ 2] = ESC_GREEN "o"
		BLOCK[ 3] = ESC_GREEN "O"
		BLOCK[ 4] = ESC_YELLOW "_"
		BLOCK[ 5] = ESC_YELLOW "."
		BLOCK[ 6] = ESC_YELLOW "o"
		BLOCK[ 7] = ESC_YELLOW "O"
		BLOCK[ 8] = ESC_RED "_"
		BLOCK[ 9] = ESC_RED "."
		BLOCK[10] = ESC_RED "o"
		BLOCK[11] = ESC_RED "O"
		if ( '"${USE_MULTICOLOR}"' && '"${USE_COLOR}"' ) {
			# Multi-color version:
			BLOCK_LEN = 12
			BLOCK_RTT_MIN = 20
			BLOCK_RTT_MAX = 220
		} else {
			# Simple version:
			BLOCK_LEN = 4
			BLOCK_RTT_MIN = 75
			BLOCK_RTT_MAX = 225
		}
	}

	if ( int('"${RTT_MIN}"') > 0 && int('"${RTT_MAX}"') > 0 ) {
		BLOCK_RTT_MIN = int('"${RTT_MIN}"')
		BLOCK_RTT_MAX = int('"${RTT_MAX}"')
	} else if ( int('"${RTT_MIN}"') > 0 ) {
		BLOCK_RTT_MIN = int('"${RTT_MIN}"')
		BLOCK_RTT_MAX = BLOCK_RTT_MIN * (BLOCK_LEN - 1)
	} else if ( int('"${RTT_MAX}"') > 0 ) {
		BLOCK_RTT_MAX = int('"${RTT_MAX}"')
		BLOCK_RTT_MIN = int(BLOCK_RTT_MAX / (BLOCK_LEN - 1))
	}

	BLOCK_RTT_RANGE = BLOCK_RTT_MAX - BLOCK_RTT_MIN
	print_response_legend()
}

############################################################
# Main loop
{
	if ( $0 ~ /^[0-9]+ bytes from .*: icmp_[rs]eq=[0-9]+ ttl=[0-9]+ time=[0-9.]+ *ms/ ) {
		# Sample line from ping:
		# 64 bytes from 8.8.8.8: icmp_seq=1 ttl=49 time=184 ms
		if ( other_line_times >= 2 ) {
			other_line_finished_repeating()
		}

		# $1 = useless prefix string
		# $2 = icmp_seq
		# $3 = ttl
		# $4 = time

		# This must be called before incrementing the last_seq variable!
		rtt = int($4)
		process_rtt(rtt)

		seq = int($2)

		while ( last_seq < seq - 1 ) {
			lost_a_packet()
		}

		# Received a packet
		print_newlines_if_needed()
		print_received_response(rtt)

		# In case of receiving multiple responses with the same seq number, it
		# is better to use "last_seq = seq" than to increment last_seq.
		last_seq = seq

		received++
		store(lastn_lost, 0)

		print_statistics_bar_if_terminal()
	} else if ( $0 ~ /^.*onnected to.*, seq=[0-9]+ time=[0-9.]+ *ms/ ) {
		# Sample line from httping:
		# connected to 200.149.119.168:80 (273 bytes), seq=0 time=129.86 ms 
		if ( other_line_times >= 2 ) {
			other_line_finished_repeating()
		}

		seq = $0
		sub(/.* seq=/, "", seq)
		seq = int(seq)

		rtt = $0
		sub(/.* time=/, "", rtt)
		rtt = int(rtt)

		process_rtt(rtt)

		while ( last_seq < seq - 1 ) {
			lost_a_packet()
		}

		# Received a packet
		print_newlines_if_needed()
		print_received_response(rtt)

		# In case of receiving multiple responses with the same seq number, it
		# is better to use "last_seq = seq" than to increment last_seq.
		last_seq = seq

		received++
		store(lastn_lost, 0)

		print_statistics_bar_if_terminal()
	} else if ( $0 == "" ) {
		# Do nothing on blank lines.
	} else if ( $0 == "error shutting down ssl" ) {
		# Common error message when using httping, ignore it.
	} else if ( $0 ~ /^Request timeout for icmp_seq [0-9]+/ ) {
		# Reply timeout is printed on Mac OS X.

		if ( other_line_times >= 2 ) {
			other_line_finished_repeating()
		}

		lost_a_packet()

		# Making sure the last_seq number is correct.
		gsub(/.* icmp_seq /, "")
		seq = int($0)
		last_seq = seq

		print_newlines_if_needed()
		print_statistics_bar_if_terminal()
	} else if ( $0 ~ /^SIGWINCH$/ ) {
		get_terminal_size()

		if ( IS_PRINTING_DOTS ) {
			if ( CURR_COL >= COLUMNS-1 ) {
				# Not enough space anyway.
			} else {
				# Making up room in case the number of lines has changed.
				printf( ESC_NEXTLINE ESC_NEXTLINE ESC_CURSORUP ESC_CURSORUP )
				# Moving to the correct column and erasing the rest of the line.
				printf( "\033[" (CURR_COL+1) "G" ESC_DEFAULT ESC_ERASELINEEND )
			}

			print_newlines_if_needed()
			print_statistics_bar_if_terminal()
		}
	} else {
		other_line_is_printed()
		original_line = $0
		gsub(/icmp_seq[= ][0-9]+/, "")
		if ( $0 == other_line ) {
			other_line_times++
			if ( '"${IS_TERMINAL}"' ) {
				other_line_is_repeated()
			}
		} else {
			other_line_finished_repeating()
			other_line = $0
			other_line_times = 1
			printf( "%s\n", original_line )
		}
	}

	# Not needed when the output is a terminal, but does not hurt either.
	fflush()
}
