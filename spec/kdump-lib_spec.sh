#!/bin/bash
Describe 'kdump-lib'
	Include ./kdump-lib.sh

	Describe 'get_system_size()'

		PROC_IOMEM=$(mktemp -t spec_test_proc_iomem_file.XXXXXXXXXX)

		cleanup() {
			rm -rf "$PROC_IOMEM"
		}

		AfterAll 'cleanup'

		ONE_GIGABYTE='000000-3fffffff : System RAM'
		Parameters
			1
			3
		End

		It 'should return correct system RAM size'
			echo -n >"$PROC_IOMEM"
			for _ in $(seq 1 "$1"); do echo "$ONE_GIGABYTE" >>"$PROC_IOMEM"; done
			When call get_system_size
			The output should equal "$1"
		End

	End

	Describe 'get_recommend_size()'
		# Testing stragety:
		# 1. inclusive for the lower bound of the range of crashkernel
		# 2. exclusive for the upper bound of the range of crashkernel
		# 3. supports ranges not sorted in increasing order

		ck="4G-64G:256M,2G-4G:192M,64G-1T:512M,1T-:12345M"
		Parameters
			1 0M
			2 192M
			64 512M
			1024 12345M
			"$((64 * 1024))" 12345M
		End

		It 'should handle all cases correctly'
			When call get_recommend_size "$1" $ck
			The output should equal "$2"
		End
	End

	Describe "_crashkernel_add()"
		Context "when the input parameter is '1G-4G:256M,4G-64G:320M,64G-:576M'"
			delta=100
			Parameters
				"1G-4G:256M,4G-64G:320M,64G-:576M" "1G-4G:356M,4G-64G:420M,64G-:676M"
				"1G-4G:256M,4G-64G:320M,64G-:576M@4G" "1G-4G:356M,4G-64G:420M,64G-:676M@4G"
				"1G-4G:1G,4G-64G:2G,64G-:3G@4G" "1G-4G:1124M,4G-64G:2148M,64G-:3172M@4G"
				"1G-4G:10000K,4G-64G:20000K,64G-:40000K@4G" "1G-4G:112400K,4G-64G:122400K,64G-:142400K@4G"
				"300M,high" "400M,high"
				"300M,low" "400M,low"
				"500M@1G" "600M@1G"
			End
			It "should add delta to the values after ':'"

				When call _crashkernel_add "$1" "$delta"
				The output should equal "$2"
			End
		End
	End

	Describe 'prepare_cmdline()'
		get_bootcpu_apicid() {
			echo 1
		}

		get_watchdog_drvs() {
			echo foo
		}

		add="disable_cpu_apicid=1 foo.pretimeout=0"

		Parameters
		       #test  cmdline       remove    add       result
			"#1"  "a b c"       ""        ""        "a b c"
			"#2"  "a b c"       "b"       ""        "a c"
			"#3"  "a b=x c"     "b"       ""        "a c"
			"#4"  "a b='x y' c" "b"       ""        "a c"
			"#5"  "a b='x y' c" "b=x"     ""        "a c"
			"#6"  "a b='x y' c" "b='x y'" ""        "a c"
			"#7"  "a b c"       ""        "x"       "a b c x"
			"#8"  "a b c"       ""        "x=1"     "a b c x=1"
			"#9"  "a b c"       ""        "x='1 2'" "a b c x='1 2'"
			"#10" "a b c"       "a"       "x='1 2'" "b c x='1 2'"
			"#11" "a b c"       "x"       "x='1 2'" "a b c x='1 2'"
		End

		It "Test $1: should generate the correct kernel command line"
			When call prepare_cmdline "$2" "$3" "$4"
			The output should equal "$5 $add"
		End
	End

End
