# Pre-flow of the Pocket project (PRE_FLOW_SCRIPT_FILE).
#  1. build_id.v with `BUILD_DATE, like the MiSTer framework's sys/build_id.tcl
#     (the core's CONF_STR uses it for the "V,v" version).
#  2. Analogue's apf/build_id.mif (build date/time readable by the Pocket).

set buildDate "`define BUILD_DATE \"[clock format [clock seconds] -format %y%m%d]\""
set outputFileName "build_id.v"
set fileData ""
if {[file exists $outputFileName]} {
	set f [open $outputFileName "r"]
	set fileData [read $f]
	close $f
}
if {$buildDate ne $fileData} {
	set f [open $outputFileName "w"]
	puts -nonewline $f $buildDate
	close $f
	post_message "Generated: [pwd]/$outputFileName: $buildDate"
}

source "apf/build_id_gen.tcl"
