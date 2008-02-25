#!/usr/bin/perl -w

use Getopt::Long;
use File::Copy;
use File::Compare;
use File::Basename;

$|= 1;
$VER= "1.1";

$opt_version= 0;
$opt_help=    0;

my $silent= "-s";
my $maria_path;     # path to "storage/maria"
my $maria_exe_path; # path to executables (ma_test1, maria_chk etc)
my $tmp= "./tmp";
my $my_progname= $0;
my $suffix;
my $md5sum;

$my_progname=~ s/.*[\/]//;
$maria_path= dirname($0) . "/..";

main();

####
#### main function
####

sub main
{
  my ($res, $table);

  if (!GetOptions("help","version"))
  {
    $flag_exit= 1;
  }
  if ($opt_version)
  {
    print "$my_progname version $VER\n";
    exit(0);
  }
  usage() if ($opt_help || $flag_exit);

  $suffix= ( $^O =~ /win/i  && $^O !~ /darwin/i ) ? ".exe" : "";
  $maria_exe_path= "$maria_path/release";
  # we use -f, sometimes -x is unexpectedly false in Cygwin
  if ( ! -f "$maria_exe_path/ma_test1$suffix" )
  {
    $maria_exe_path= "$maria_path/relwithdebinfo";
    if ( ! -f "$maria_exe_path/ma_test1$suffix" )
    {
      $maria_exe_path= "$maria_path/debug";
      if ( ! -f "$maria_exe_path/ma_test1$suffix" )
      {
        $maria_exe_path= $maria_path;
        if ( ! -f "$maria_exe_path/ma_test1$suffix" )
        {
          die("Cannot find ma_test1 executable\n");
        }
      }
    }
  }

  # Test if we should use md5sum or digest -a md5

  if (defined(my_which("md5sum")))
  {
    $md5sum="md5sum";
  }
  elsif (defined(my_which("md5")))
  {
  $md5sum="md5";
  }
  elsif (defined(my_which("digest")))
  {
  $md5sum="digest -a md5";
  }
  else
  {
    die "Can't find either md5sum or digest. Please install one of them"
  }

  # test data is always put in the current directory or a tmp subdirectory
  # of it

  if (! -d "$tmp")
  {
    mkdir $tmp;
  }
  print "MARIA RECOVERY TESTS\n";
  $res= `$maria_exe_path/maria_read_log$suffix --help | grep IDENTICAL_PAGES_AFTER_RECOVERY`;

  if (length($res))
  {
    print "Recovery tests require compilation with DBUG\n";
    print "Aborting test\n";
    # In the future, we will not abort but use maria_chk --zerofill-keep-lsn
    # for comparisons in non-debug builds.
    # For now we just skip the test, pretending it passed (nothing is
    # alarming).
    exit(0);
  }

  # To not flood the screen, we redirect all the commands below to a text file
  # and just give a final error if their output is not as expected

  open (MY_LOG, ">$tmp/ma_test_recovery.output") or die "Can't open log file\n";
  print MY_LOG "Testing the REDO PHASE ALONE\n";

  # runs a program inserting/deleting rows, then moves the resulting table
  # elsewhere; applies the log and checks that the data file is
  # identical to the saved original.

  my @t= ("ma_test1$suffix $silent -M -T -c",
          "ma_test2$suffix $silent -L -K -W -P -M -T -c -d500",
          "ma_test2$suffix $silent -M -T -c -b65000",
          "ma_test2$suffix $silent -M -T -c -b65000 -d800");

  foreach my $prog (@t)
  {
    unlink <maria_log.* maria_log_control>;
    my $prog_no_suffix= $prog;
    $prog_no_suffix=~ s/$suffix// if ($suffix);
    print MY_LOG "TEST WITH $prog_no_suffix\n";
    $res= `$maria_exe_path/$prog`;
    print MY_LOG $res;
    # derive table's name from program's name
    if ($prog =~ m/ma_(test[0-9]+).*/)
    {
      $table= $1;
    }
    $com=  "$maria_exe_path/maria_chk$suffix -dvv $table ";
    $com.= "| grep -v \"Creation time:\" | grep -v \"file length\" ";
    $com.= "> $tmp/maria_chk_message.good.txt 2>&1";
    `$com`;
    my $checksum=`$maria_exe_path/maria_chk$suffix -dss $table`;
    move("$table.MAD", "$tmp/$table-good.MAD") ||
      die "Can't move $table.MAD to $tmp/$table-good.MAD\n";
    move("$table.MAI", "$tmp/$table-good.MAI") ||
      die "Can't move $table.MAI to $tmp/$table-good.MAI\n";
    apply_log($table, "shouldnotchangelog");
    check_table_is_same($table, $checksum);
    $res= physical_cmp($table, "$tmp/$table-good");
    print MY_LOG $res;
    print MY_LOG "testing idempotency\n";
    apply_log($table, "shouldnotchangelog");
    check_table_is_same($table, $checksum);
    $res= physical_cmp($table, "$tmp/$table-good");
    print MY_LOG $res;
  }

  print MY_LOG "Testing the REDO AND UNDO PHASE\n";
  # The test programs look like:
  # work; commit (time T1); work; exit-without-commit (time T2)
  # We first run the test program and let it exit after T1's commit.
  # Then we run it again and let it exit at T2. Then we compare
  # and expect identity.

  my @take_checkpoints= ("no", "yes");
  my @blobs= ("", "-b32768");
  my @test_undo= (1, 2, 3, 4);
  my @t2= ("ma_test1$suffix $silent -M -T -c -N blob -H1",
           "--testflag=1",
           "--testflag=2 --test-undo=",
           "ma_test1$suffix $silent -M -T -c -N blob -H2",
           "--testflag=3",
           "--testflag=4 --test-undo=",
           "ma_test1$suffix $silent -M -T -c -N blob -H2",
           "--testflag=2",
           "--testflag=3 --test-undo=",
           "ma_test2$suffix $silent -L -K -W -P -M -T -c blob -H1",
           "-t1",
           "-t2 -A",
           "ma_test2$suffix $silent -L -K -W -P -M -T -c blob -H1",
           "-t1",
           "-t6 -A");

  foreach my $take_checkpoint (@take_checkpoints)
  {
    my ($i, $j, $k, $commit_run_args, $abort_run_args);
    # we test table without blobs and then table with blobs
    for ($i= 0; defined($blobs[$i]); $i++)
    {
      for ($j= 0; defined($test_undo[$j]); $j++)
      {
        # first iteration tests rollback of insert, second tests rollback of delete
        # -N (create NULL fields) is needed because --test-undo adds it anyway
        for ($k= 0; defined($t2[$k]); $k+= 3)
        {
          $prog= $t2[$k];
          $prog=~ s/blob/$blobs[$i]/;
          if ("$take_checkpoint" eq "no") {
            $prog=~ s/\s+\-H[0-9]+//;
          }
          $commit_run_args= $t2[$k + 1];
          $abort_run_args= $t2[$k + 2];
          unlink <maria_log.* maria_log_control>;
          my $prog_no_suffix= $prog;
          $prog_no_suffix=~ s/$suffix// if ($suffix);
          print MY_LOG "TEST WITH $prog_no_suffix $commit_run_args (commit at end)\n";
          $res= `$maria_exe_path/$prog $commit_run_args`;
          print MY_LOG $res;
          # derive table's name from program's name
          if ($prog =~ m/ma_(test[0-9]+).*/)
          {
            $table= $1;
          }
          $com=  "$maria_exe_path/maria_chk$suffix -dvv $table ";
          $com.= "| grep -v \"Creation time:\" | grep -v \"file length\" ";
          $com.= "> $tmp/maria_chk_message.good.txt 2>&1";
          $res= `$com`;
          print MY_LOG $res;
          $checksum= `$maria_exe_path/maria_chk$suffix -dss $table`;
          move("$table.MAD", "$tmp/$table-good.MAD") ||
            die "Can't move $table.MAD to $tmp/$table-good.MAD\n";
          move("$table.MAI", "$tmp/$table-good.MAI") ||
            die "Can't move $table.MAI to $tmp/$table-good.MAI\n";
          unlink <maria_log.* maria_log_control>;
          print MY_LOG "TEST WITH $prog_no_suffix $abort_run_args$test_undo[$j] (additional aborted work)\n";
          $res= `$maria_exe_path/$prog $abort_run_args$test_undo[$j]`;
          print MY_LOG $res;
          copy("$table.MAD", "$tmp/$table-before_undo.MAD") ||
            die "Can't copy $table.MAD to $tmp/$table-before_undo.MAD\n";
          copy("$table.MAI", "$tmp/$table-before_undo.MAI") ||
            die "Can't copy $table.MAI to $tmp/$table-before_undo.MAI\n";

          # The lines below seem unneeded, will be removed soon
          # We have to copy and restore logs, as running maria_read_log will
          # change the maria_control_file
          #    rm -f $tmp/maria_log.* $tmp/maria_log_control
          #    cp $maria_path/maria_log* $tmp

          if ($test_undo[$j] != 3) {
            apply_log($table, "shouldchangelog"); # should undo aborted work
          } else {
            # probably nothing to undo went to log or data file
            apply_log($table, "dontknow");
          }
          copy("$table.MAD", "$tmp/$table-after_undo.MAD") ||
            die "Can't copy $table.MAD to $tmp/$table-after_undo.MAD\n";
          copy("$table.MAI", "$tmp/$table-after_undo.MAI") ||
            die "Can't copy $table.MAI to $tmp/$table-after_undo.MAI\n";

          # It is impossible to do a "cmp" between .good and .after_undo,
          # because the UNDO phase generated log
          # records whose LSN tagged pages. Another reason is that rolling back
          # INSERT only marks the rows free, does not empty them (optimization), so
          # traces of the INSERT+rollback remain.

          check_table_is_same($table, $checksum);
          print MY_LOG "testing idempotency\n";
          apply_log($table, "shouldnotchangelog");
          check_table_is_same($table, $checksum);
          $res= physical_cmp($table, "$tmp/$table-after_undo");
          print MY_LOG $res;
          print MY_LOG "testing applying of CLRs to recreate table\n";
          unlink <$table.MA?>;
          #    cp $tmp/maria_log* $maria_path  #unneeded
          apply_log($table, "shouldnotchangelog");
          check_table_is_same($table, $checksum);
          $res= physical_cmp($table, "$tmp/$table-after_undo");
          print MY_LOG $res;
        }
        unlink <$table.* $tmp/$table* $tmp/maria_chk_*.txt $tmp/maria_read_log_$table.txt>;
      }
    }
  }

  if ($? >> 8) {
    print "Some test failed\n";
    exit(1);
  }

  # also note that maria_chk -dvv shows differences for ma_test2 in UNDO phase,
  # this is normal: removing records does not shrink the data/key file,
  # does not put back the "analyzed,optimized keys"(etc) index state.
  `diff -b $maria_path/unittest/ma_test_recovery.expected $tmp/ma_test_recovery.output`;
  if ($? >> 8) {
    print "UNEXPECTED OUTPUT OF TESTS, FAILED\n";
    print "For more info, do diff -b $maria_path/unittest/ma_test_recovery.expected ";
    print "$tmp/ma_test_recovery.output\n";
    exit(1);
  }
  print "ALL RECOVERY TESTS OK\n";
}

####
#### check_table_is_same
####

sub check_table_is_same
{
  my ($table, $checksum)= @_;
  my ($com, $checksum2, $res);

  # Computes checksum of new table and compares to checksum of old table
  # Shows any difference in table's state (info from the index's header)
  # Data/key file length is random in ma_test2 (as it uses srand() which
  # may differ between machines).

  $com=  "$maria_exe_path/maria_chk$suffix -dvv $table | grep -v \"Creation time:\" ";
  $com.= "| grep -v \"file length\"> $tmp/maria_chk_message.txt 2>&1";
  $res= `$com`;
  print MY_LOG $res;
  $res= `$maria_exe_path/maria_chk$suffix -s -e --read-only $table`;
  print MY_LOG $res;
  $checksum2= `$maria_exe_path/maria_chk$suffix -dss $table`;
  if ("$checksum" ne "$checksum2")
  {
    print MY_LOG "checksum differs for $table before and after recovery\n";
    return 1;
  }

  $com=  "diff $tmp/maria_chk_message.good.txt $tmp/maria_chk_message.txt ";
  $com.= "> $tmp/maria_chk_diff.txt || true";
  $res= `$com`;
  print MY_LOG $res;

  if (-s "$tmp/maria_chk_diff.txt")
  {
    print MY_LOG "Differences in maria_chk -dvv, recovery not yet perfect !\n";
    print MY_LOG "========DIFF START=======\n";
    open(MY_FILE, "<$tmp/maria_chk_diff.txt") || die "Can't open file maria_chk_diff.txt\n";
    while (<MY_FILE>)
    {
      print MY_LOG $_;
    }
    close(MY_FILE);
    print MY_LOG "========DIFF END=======\n";
  }
}

####
#### apply_log
####

sub apply_log
{
  my ($table, $shouldchangelog)= @_;
  my ($log_md5);

  # applies log, can verify if applying did write to log or not

  if ("$shouldchangelog" ne "shouldnotchangelog" &&
      "$shouldchangelog" ne "shouldchangelog" &&
      "$shouldchangelog" ne "dontknow" )
  {
    print MY_LOG "bad argument '$shouldchangelog'\n";
    return 1;
  } 
  $log_md5= `$md5sum maria_log.*`;

  print MY_LOG "applying log\n";
  `$maria_exe_path/maria_read_log$suffix -a > $tmp/maria_read_log_$table.txt`;
  $log_md5_2= `$md5sum maria_log.*`;
  if ("$log_md5" ne "$log_md5_2" )
  {
    if ("$shouldchangelog" eq "shouldnotchangelog")
    {
      print MY_LOG "maria_read_log should not have modified the log\n";
      return 1;
    }
  }
  elsif ("$shouldchangelog" eq "shouldchangelog")
  {
    print MY_LOG "maria_read_log should have modified the log\n";
    return 1;
  }
}


sub my_which
{
  my ($command) = @_;
  my (@paths, $path);

  return $command if (-f $command && -x $command);
  @paths = split(':', $ENV{'PATH'});
  foreach $path (@paths)
  {
    $path .= "/$command";
    return $path if (-f $path && -x $path);
  }
  return undef();
}


####
#### physical_cmp: compares two tables (MAI and MAD) physically;
#### uses zerofill-keep-lsn to reduce irrelevant differences.
####

sub physical_cmp
{
  my ($table1, $table2)= @_;
  my ($zerofilled, $ret_text);
  foreach my $file_suffix ("MAD", "MAI")
  {
    my $file1= "$table1.$file_suffix";
    my $file2= "$table2.$file_suffix";
    my ($error_text, $differences_text)=
      ("error in comparison of $file1 and $file2\n",
      "$file1 and $file2 differ\n");
    my $res= File::Compare::compare($file1, $file2);
    return $error_text if ($res == -1);
    if ($res == 1 # they differ
        and !$zerofilled)
    {
      # let's try with --zerofill-keep-lsn
      $zerofilled= 1; # but no need to do it twice
      foreach my $table ($table1, $table2)
      {
        $com= "$maria_exe_path/maria_chk$suffix -s --zerofill-keep-lsn $table";
        $res= `$com`;
        print MY_LOG $res;
      }
      $res= File::Compare::compare($file1, $file2);
      return $error_text if ($res == -1);
    }
    $ret_text.= $differences_text if ($res != 0);
  }
}


####
#### usage
####

sub usage
{
  print <<EOF;
$my_progname version $VER

Description:

Run various maria recovery tests and print the results

Options
--help             Show this help and exit.
--version          Show version number and exit.
EOF
  exit(0);
}
