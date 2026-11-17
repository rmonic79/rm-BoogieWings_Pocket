# Post-flow of the Pocket project (POST_FLOW_SCRIPT_FILE).
# The Pocket wants the bitstream with the bits of every byte reversed (.rbf_r):
#   output_files/<revision>.rbf -> output_files/<revision>.rbf_r
#                                  output_files/<revision>_yyyymmdd.rbf_r
# If the dated copy already exists (several builds on the same day):
# _yyyymmdd_1, _2, ... The original .rbf is not touched.

set rev [lindex $quartus(args) 2]
if {$rev eq ""} { set rev [lindex $quartus(args) 1] }

set out_dir "output_files"
set src     "$out_dir/$rev.rbf"

if {![file exists $src]} {
	post_message "pocket_post_flow: $src not found, skipped"
	return
}

set f [open $src rb]
set data [read $f]
close $f

# bit-reversal table for the 256 values of a byte
set rev_tab {}
for {set i 0} {$i < 256} {incr i} {
	set r 0
	for {set b 0} {$b < 8} {incr b} {
		if {$i & (1 << $b)} { set r [expr {$r | (1 << (7 - $b))}] }
	}
	lappend rev_tab $r
}

binary scan $data cu* bytes
set out {}
foreach v $bytes { lappend out [lindex $rev_tab $v] }
set outdata [binary format c* $out]

set dst "$out_dir/$rev.rbf_r"
set f [open $dst wb]
puts -nonewline $f $outdata
close $f

set stamp [clock format [clock seconds] -format %Y%m%d]
set dated "$out_dir/${rev}_${stamp}.rbf_r"
if {[file exists $dated]} {
	set n 1
	while {[file exists "$out_dir/${rev}_${stamp}_${n}.rbf_r"]} { incr n }
	set dated "$out_dir/${rev}_${stamp}_${n}.rbf_r"
}
file copy -force $dst $dated

post_message "pocket_post_flow: created $dst and $dated ([string length $outdata] bytes)"
