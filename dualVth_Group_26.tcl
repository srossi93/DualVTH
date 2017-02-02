proc cell_swapping {cellName_list Vth_type} {
  if { $Vth_type != "LVT" && $Vth_type != "HVT" } {
    puts "${Vth_type}: Vth_type wrong!"
    return 0
  }

  if { [llength cellName_list] == 0 } {
    puts "Void list"
    return 0
  }
  set number_of_swapped_cells 0
  foreach cell $cellName_list {
    set cell_name [get_attribute $cell ref_name]
    regexp {([A-Z0-9]+)_([A-Z][A-Z])([S]?_[A-Z0-9]+)} $cell_name -> lib type gate

    set swapped_cells [size_cell $cell CORE65LP${Vth_type}/${lib}_[string index $type 0][string index $Vth_type 0]${gate}]
    set list_swapped_cells [get_object $swapped_cells]
    set number_of_swapped_cells [expr $number_of_swapped_cells + [llength list_swapped_cells]]
    unset list_swapped_cells

  }

  return $number_of_swapped_cells
}

# Returns all the cells belonging to a specific path
proc get_cells_in_path {path} {

  set critical_path_cell_list [list]

  foreach_in_collection timing_points [get_attribute $path points] {
    set pin_name [get_attribute [get_attribute $timing_points object] full_name]
    if {[string index $pin_name "0"] == "U"} {
      set cell_name [lindex [split $pin_name '/'] 0]
      if {$cell_name != [lindex $critical_path_cell_list end]} {
        lappend critical_path_cell_list $cell_name
      }
    }
  }

  return $critical_path_cell_list
}

# Check requirements
# Return : 0 if not met
#          1 if yes
proc check_requirements {arrival_time critical_paths slack_win} {

  set worst_arrival [get_attribute [get_timing_paths] arrival]

  if {([get_attribute [get_timing_paths] slack] < 0) || ($worst_arrival > $arrival_time)} {
    #puts "NEGATIVE SLACK: $worst_slack"
    return 0
  }

  set list_path [get_timing_paths -slack_lesser_than $slack_win -nworst [expr $critical_paths + 1]]

  set number_of_path 0
  foreach_in_collection path $list_path {
    incr number_of_path
  }
  unset list_path

  #puts $number_of_path
  if {$number_of_path > $critical_paths} {
    #puts "OVERFLOW IN WINDOW: $number_of_path"
    return 0
  }

  return 1
}

proc reset {} {
  set cells [get_cells]
  foreach_in_collection cell $cells {
    cell_swapping $cell LVT
  }
}

proc is_lvt {cell} {
  set cell_name [get_attribute $cell ref_name]
  regexp {([A-Z0-9]+)_([A-Z][A-Z])([S]?_[A-Z0-9]+)} $cell_name -> lib type gate
  if {![string compare $type "LL"]} {
    return 1
  }
  return 0
}

proc leak_power {} {
  set report_text ""  ;# Contains the output of the report_power command
  set lnr 3           ;# Leakage info is in the 2nd line from the bottom
  set wnr 5           ;# Leakage info is the eighth word in the $lnr line
  redirect -variable report_text {report_power}
  set report_text [split $report_text "\n"]
  return [format "%0.9f" [lindex [regexp -inline -all -- {\S+} [lindex $report_text [expr [llength $report_text] - $lnr]]] $wnr]]
}

proc parse_arguments {arg0 opt0 arg1 opt1 arg2 opt2} {
  set main_args {-1 -1 -1}
  set arguments {}
  set options {}

  lappend arguments $arg0 $arg1 $arg2
  lappend options $opt0 $opt1 $opt2

  for {set i 0} {$i < 3} {incr i} {
    if {![string compare "-arrivalTime" [lindex $arguments $i]]} {
            lset main_args 0 [lindex $options $i]
    }
    if {![string compare "-criticalPaths" [lindex $arguments $i]]} {
            lset main_args 1 [lindex $options $i]
    }
    if {![string compare "-slackWin" [lindex $arguments $i]]} {
            lset main_args 2 [lindex $options $i]
    }
  }

  unset arguments
  unset options

  return $main_args
}



proc leakage_opt {arg0 opt0 arg1 opt1 arg2 opt2} {
  suppress_message TIM-104
  suppress_message NLE-019
  suppress_message UID-85

  set argv [parse_arguments $arg0 $opt0 $arg1 $opt1 $arg2 $opt2]

  # input parameters
  set arrival_time   [lindex $argv 0]
  set critical_paths [lindex $argv 1]
  set slack_win      [lindex $argv 2]

#  puts "arrival_time   : $arrival_time  "
#  puts "critical_paths : $critical_paths"
#  puts "slack_win      : $slack_win     "

  set clock_period [get_attribute [get_clock] period]
  if {($arrival_time > $clock_period) || ($arrival_time < $slack_win) } {
    puts "Error"
    set return_values {-1 -1 -1 -1}
    return $return_values
  }

	set cells [get_object [get_cells]]
	set n_cells [llength $cells]
  set n_per_cluster [format "%d" [expr int(floor($n_cells / 250) + 1)]]

  set HVT_cells 0
  set initial_leakage [leak_power]

  set start_time [clock clicks -milliseconds]

  for {set i 0} {$i < [expr $n_cells/$n_per_cluster]} {incr i} {
    set cluster [list]
		for {set j 0} {$j < $n_per_cluster} {incr j} {
      lappend cluster [lindex $cells [expr $i * $n_per_cluster + $j]]
		}
    set HVT_cells [expr $HVT_cells + [cell_swapping $cluster HVT]]
    set flag [check_requirements $arrival_time $critical_paths $slack_win]
    if {$flag == 0} {
      set HVT_cells [expr $HVT_cells - [cell_swapping $cluster LVT]]
    }
	}

  set stop_time [clock clicks -milliseconds]
  set final_leakage [leak_power]
  set power_saving [format {%0.4f} [expr ($initial_leakage - $final_leakage) / $initial_leakage]]
  set exec_time [format {%0.1f} [expr ($stop_time - $start_time) / 1000]]
  set HVT_perc [format {%0.2f} [expr 1.0*$HVT_cells / $n_cells]]
  set LVT_perc [expr 1 - $HVT_perc]

#  puts "Cells per cluster: $n_per_cluster"
#  puts "Leakage power    : [leak_power]"
#  puts "Time             : $exec_time"
#  puts "HVT Cells        : $HVT_cells"
#  puts "LVT Cells        : [expr $n_cells - $HVT_cells]"

  set return_values [list]
  lappend return_values $power_saving
  lappend return_values $exec_time
  lappend return_values $LVT_perc
  lappend return_values $HVT_perc

  return $return_values
}
