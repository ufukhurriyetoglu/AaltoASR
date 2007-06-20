#!/usr/bin/perl

# DO NOT USE THIS SCRIPT DIRECTLY! Copy it to your own directory and
# modify appropriately. You MUST modify at least the path settings,
# training file list and BASE_ID/Initial model names!

# Run this script at itl-cl1, as it uses GridEngine for scheduling
# the parallel processes.

use locale;
use strict;

# Model name
my $BASE_ID="mfcc";

# Path settings
my $BINDIR="/home/jpylkkon/bin/aku";
my $SCRIPTDIR="$BINDIR/scripts";
my $HMMDIR="/share/puhe/jpylkkon/hmms";
my $workdir="/share/work/jpylkkon/aku_work";
my $lna_outdir = "/share/work/jpylkkon/lnas/".$BASE_ID;

# Training file list
my $RECIPE="/share/puhe/jpylkkon/train/train.recipe";
my $lna_recipe="/share/puhe/jpylkkon/train/test.recipe";

# Initial model names
my $init_model = $HMMDIR."/".$BASE_ID;      # Created in tying
my $init_cfg = $HMMDIR."/".$BASE_ID.".cfg"; # Used in tying and training

# Batch settings
my $NUM_BATCHES = 2; # Number of processes in parallel

# Baum-Welch settings
my $USE_BAUM_WELCH = 1; # If 0, the script must call align appropriately
my $FORWARD_BEAM = 15;
my $BACKWARD_BEAM = 200;
my $AC_SCALE = 1; # Acustic scaling (For ML 1, for MMI 1/LMSCALE)

# Alignment settings
my $ALIGN_WINDOW = 4000;
my $ALIGN_BEAM = 1000;
my $ALIGN_SBEAM = 100;

# Context phone tying options
my $TIE_USE_OUT_PHN = 0;
my $TIE_RULES = "$SCRIPTDIR/finnish_rules.txt";
my $TIE_MIN_COUNT = 1500;
my $TIE_MIN_GAIN = 1200;
my $TIE_MAX_LOSS = 1200;

# Gaussian splitting options
my $SPLIT_MIN_OCCUPANCY = 250;
my $SPLIT_MAX_GAUSSIANS = 24;

# Minimum variance
my $MINVAR = 0.1;

# MLLT options
my $mllt_start_iter = 14; # At which iteration MLLT estimation should begin
my $MLLT_MODULE_NAME = "transform";

# Training iterations
my $num_train_iter = 22;
my $split_frequency = 3; # How many EM iterations between Gaussian splits
my $split_stop_iter = 14; # Iteration after which no more splits are done

# Adaptation settings
my $VTLN_MODULE = "vtln";
my $SPKC_FILE = ""; # For initialization see e.g. $SCRIPTDIR/vtln_default.spkc

# Misc settings
my $FILEFORMAT = "-R"; # Empty for wav files, -R for raw
my $VERBOSITY = 1;


######################################################################
# Training script begins
######################################################################

# Create own working directory
my $tempdir = $workdir."/".$BASE_ID;
mkdir $tempdir;
chdir $tempdir || die("Could not chdir to $tempdir");

# Generate initial model by context phone tying using existing alignments
context_phone_tying($tempdir, $init_model, $init_cfg);

# Convert the generated full covariance model to diagonal model
convert_full_to_diagonal($init_model);

# Create the hmmnet file
generate_hmmnet_files($tempdir, $init_model);

# ML/EM training
my $om;
$om=ml_train($tempdir, 1, $num_train_iter, $init_model, $init_cfg,
             $mllt_start_iter, $split_frequency, $split_stop_iter);

# Estimate duration model
align($tempdir, $om, $RECIPE);
estimate_dur_model($om);

# VTLN
#align($tempdir, $om, $RECIPE);
#estimate_vtln($tempdir, $om, $RECIPE, $om.".spkc");


# Generate lnas for the final model
generate_lnas($tempdir, $om, $lna_recipe, $lna_outdir);



sub context_phone_tying {
  my $temp_dir = shift(@_);
  my $out_model = shift(@_);
  my $im_cfg = shift(@_);
  my $phn_flag = "";
  $phn_flag = "-O" if ($TIE_USE_OUT_PHN);

  my $batch_info = make_single_batch($temp_dir, $BASE_ID, "$BINDIR/tie -c $im_cfg -o $out_model -r $RECIPE $phn_flag $FILEFORMAT -u $TIE_RULES --count $TIE_MIN_COUNT --sgain $TIE_MIN_GAIN --mloss $TIE_MAX_LOSS -i $VERBOSITY\n");
  submit_and_wait($batch_info);

  if (!(-e $out_model.".ph")) {
    die "Error in context phone tying\n";
  }
}


sub convert_full_to_diagonal {
  my $im = shift(@_);
  my $gk = $im.".gk";
  my $gk_backup = $im."_full.gk";
  
  system("cp $gk $gk_backup");
  system("$BINDIR/gconvert -g $gk_backup -o $gk -d");
}


sub ml_train {
  my $temp_dir = shift(@_);
  my $iter_init = shift(@_);
  my $iter_end = shift(@_);

  my $im = shift(@_);
  my $im_cfg = shift(@_);

  my $mllt_start = shift(@_);
  my $mllt_flag = 0;

  my $split_frequency = shift(@_);
  my $split_stop_iter = shift(@_);
  my $split_flag;

  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
  my $dstring = "$mday.".($mon+1).".".(1900+$year);
  my $model_base = "$HMMDIR/${BASE_ID}_${dstring}";

  my $stats_list_file = "stats.lst";
  my $batch_info;

  for (my $i = $iter_init; $i <= $iter_end ; $i ++) {

    print "Iteration ".$i."\n" if ($VERBOSITY > 0);
    my $om = $model_base."_".$i;

    $mllt_flag = 1 if ($mllt_start && $i >= $mllt_start);

    collect_stats($temp_dir, $im, $im_cfg, $stats_list_file,
                  $mllt_flag);

    $split_flag = 0;
    $split_flag = 1 if ($split_frequency && $i < $split_stop_iter &&
                        (($i-1) % $split_frequency) == 0);
    ml_estimate($temp_dir, $im, $im_cfg, $om, $stats_list_file, $MINVAR,
                $mllt_flag, $split_flag);
    
    # Check the models were really created
    if (!(-e $om.".ph")) {
      die "Error in training, no models were written\n";
    }

    # Read input from previously written model
    $im = $om;
    $im_cfg = $om.".cfg";
  }
  return $im;
}


sub collect_stats {
  my $temp_dir = shift(@_);
  my $model_base = shift(@_);
  my $cfg = shift(@_);
  my $stats_list_file = shift(@_);
  my $mllt_flag = shift(@_);
  my $batch_options;
  my ($scriptfile, $statsfile, $keyfile);
  my $fh;
  my $batch_info = get_empty_batch_info();
  my $list_fh;
  my $bw_option = "";
  my $mllt_option = "";
  my $spkc_switch = "";
  $bw_option = "-H" if ($USE_BAUM_WELCH);
  $spkc_switch = "-S $SPKC_FILE" if ($SPKC_FILE ne "");

  $mllt_option = "--mllt" if ($mllt_flag);

  open $list_fh, "> $stats_list_file" || die "Could not open $stats_list_file";

  $scriptfile = "genstats_${BASE_ID}.sh";
  open $fh, "> $scriptfile" || die "Could not open $scriptfile";
  $statsfile = "stats";
  $keyfile = "stats_ready";
  $batch_options = get_aku_batch_options($NUM_BATCHES, $batch_info);
  if ($NUM_BATCHES > 1) {
    for (my $i = 1; $i <= $NUM_BATCHES; $i++) {
      my $cur_keyfile = $keyfile."_$i";
      my $cur_statsfile = $statsfile."_$i";
      print $list_fh $cur_statsfile."\n";
      unlink(glob($cur_statsfile.".*"));
      push @{$batch_info->{"key"}}, $cur_keyfile;
    }
    $statsfile = $statsfile."_\$SGE_TASK_ID";
    $keyfile = $keyfile."_\$SGE_TASK_ID";
  } else {
    unlink(glob($statsfile.".*"));
    push @{$batch_info->{"key"}}, $keyfile;
    print $list_fh $statsfile."\n";
  }
  print $fh get_batch_script_pre_string($temp_dir, $temp_dir);
  print $fh "$BINDIR/stats -b $model_base -c $cfg -r $RECIPE $bw_option -o $statsfile $FILEFORMAT -F $FORWARD_BEAM -W $BACKWARD_BEAM -A $AC_SCALE $spkc_switch $batch_options -t -i $VERBOSITY $mllt_option\n";
  print $fh "touch $keyfile\n";
  close($fh);
  push @{$batch_info->{"script"}}, $scriptfile;
  close($list_fh);
  submit_and_wait($batch_info);
}


sub ml_estimate {
  my $temp_dir = shift(@_);
  my $im = shift(@_);
  my $im_cfg = shift(@_);
  my $om = shift(@_);
  my $stats_list_file = shift(@_);
  my $minvar = shift(@_);
  my $mllt_flag = shift(@_);
  my $split_flag = shift(@_);
  my $extra_options = "";

  $extra_options = "--mllt $MLLT_MODULE_NAME" if ($mllt_flag);
  $extra_options = $extra_options." --split --minocc $SPLIT_MIN_OCCUPANCY --maxg $SPLIT_MAX_GAUSSIANS" if ($split_flag);

  my $batch_info = make_single_batch($temp_dir, $BASE_ID, "$BINDIR/estimate -b $im -c $im_cfg -L $stats_list_file -o $om -t -i $VERBOSITY --minvar $minvar --ml -s ${BASE_ID}_loglikelihoods $extra_options\n");
  submit_and_wait($batch_info, 10); # Reduced batch check interval
}


sub generate_hmmnet_files {
  my $temp_dir = shift(@_);
  my $im = shift(@_);
  my $batch_info = make_single_batch($temp_dir, $BASE_ID, "export PERL5LIB=$SCRIPTDIR\n$SCRIPTDIR/make_hmmnets.pl $im.ph $RECIPE");
  submit_and_wait($batch_info);
}


sub align {
  my $temp_dir = shift(@_);
  my $model = shift(@_);
  my $recipe = shift(@_);
  my $spkc_file = shift(@_);
  my ($scriptfile, $keyfile, $touch_keyfile);
  my $batch_info = get_empty_batch_info();
  my $fh;
  my $batch_options;
  my $spkc_switch = "";
  $spkc_switch = "-S $spkc_file" if ($spkc_file ne "");

  $scriptfile = "align_${BASE_ID}.sh";
  $keyfile = "align_ready";
  $touch_keyfile = $keyfile;
  $touch_keyfile = $touch_keyfile."_\$SGE_TASK_ID" if ($NUM_BATCHES > 1);

  $batch_options = get_aku_batch_options($NUM_BATCHES, $batch_info);
  open $fh, "> $scriptfile" || die "Could not open $scriptfile";
  print $fh get_batch_script_pre_string($temp_dir, $temp_dir);
  print $fh "$BINDIR/align -b $model -c $model.cfg -r $recipe --swins $ALIGN_WINDOW --beam $ALIGN_BEAM --sbeam $ALIGN_SBEAM $FILEFORMAT $spkc_switch $batch_options -i 1\n";
  print $fh "touch $touch_keyfile\n";
  close($fh);

  push @{$batch_info->{"script"}}, $scriptfile;
  fill_aku_batch_keys($NUM_BATCHES, $keyfile, $batch_info);

  submit_and_wait($batch_info);
}


# NOTE: Uses alignments
sub estimate_vtln {
  my $temp_dir = shift(@_);
  my $model = shift(@_);
  my $recipe = shift(@_);
  my $out_file = shift(@_);
  my ($scriptfile, $keyfile, $touch_keyfile, $temp_out);
  my $batch_info = get_empty_batch_info();
  my $fh;
  my $batch_options;
  $scriptfile = "vtln_${BASE_ID}.sh";
  $keyfile = "vtln_ready";
  $touch_keyfile = $keyfile;
  $temp_out = $out_file;
  if ($NUM_BATCHES > 1) {
    $touch_keyfile = $touch_keyfile."_\$SGE_TASK_ID";
    $temp_out = "vtln_temp_\$SGE_TASK_ID.spkc";
  }
  $batch_options = get_aku_batch_options($NUM_BATCHES, $batch_info);
  open $fh, "> $scriptfile" || die "Could not open $scriptfile";
  print $fh get_batch_script_pre_string($temp_dir, $temp_dir);
  print $fh "$BINDIR/vtln -b $model -c $model.cfg -r $recipe -O $FILEFORMAT -v $VTLN_MODULE -S $SPKC_FILE -o $temp_out $batch_options -i 1\n";
  print $fh "touch $touch_keyfile\n";
  close($fh);

  push @{$batch_info->{"script"}}, $scriptfile;
  fill_aku_batch_keys($NUM_BATCHES, $keyfile, $batch_info);

  submit_and_wait($batch_info);
  if ($NUM_BATCHES > 1) {
    system("cat vtln_temp_*.spkc > $out_file") && die("vtln estimation failed");
  }
}


# NOTE: Uses alignments
sub estimate_dur_model {
  my $om = shift(@_);
  system("$BINDIR/dur_est -p $om.ph -r $RECIPE -O --gamma $om.dur --skip 8") && die("Error estimating duration models");
}


sub generate_lnas {
  my $temp_dir = shift(@_);
  my $model = shift(@_);
  my $recipe = shift(@_);
  my $out_dir = shift(@_);
  my $spkc_file = shift(@_);
  my ($scriptfile, $keyfile, $touch_keyfile);
  my $fh;
  my $batch_options;
  my $batch_info = get_empty_batch_info();

  my $spkc_switch = "";
  $spkc_switch = "-S $spkc_file" if ($spkc_file ne "");

  mkdir $out_dir;

  $scriptfile = "lna_${BASE_ID}.sh";
  $keyfile = "lna_ready";
  $touch_keyfile = $keyfile;
  $touch_keyfile = $touch_keyfile."_\$SGE_TASK_ID" if ($NUM_BATCHES > 1);

  $batch_options = get_aku_batch_options($NUM_BATCHES, $batch_info);
    
  open $fh, "> $scriptfile" || die "Could not open $scriptfile";
  print $fh get_batch_script_pre_string($temp_dir, $temp_dir);
  print $fh "$BINDIR/phone_probs -b $model -c $model.cfg -r $recipe -o $out_dir $FILEFORMAT $spkc_switch $batch_options -i 1\n";
  print $fh "touch $touch_keyfile\n";
  close($fh);

  push @{$batch_info->{"script"}}, $scriptfile;
  fill_aku_batch_keys($NUM_BATCHES, $keyfile, $batch_info);

  submit_and_wait($batch_info);
}


###############################
# Aku-specific batch functions
###############################

sub get_aku_batch_options {
  my $num_batches = shift(@_);
  my $info = shift(@_);
  my $options = "";
  if ($num_batches > 1) {
    $info->{"qsub_options"} = "-t 1-$num_batches";
    $options = "-B $num_batches -I \$SGE_TASK_ID";
  }
  return $options;
}

sub fill_aku_batch_keys {
  my $num_batches = shift(@_);
  my $keyfile = shift(@_);
  my $info = shift(@_);
  if ($num_batches > 1) {
    for (my $i = 1; $i <= $num_batches; $i++) {
      push @{$info->{"key"}}, $keyfile."_$i";
    }
  }
  else {
    push @{$info->{"key"}}, $keyfile;
  }
}

###############################
# Generic batch functions
###############################

sub get_empty_batch_info {
  my $batch_info = {};
  $batch_info->{"script"} = [];
  $batch_info->{"key"} = [];
  $batch_info->{"qsub_options"} = "";
  return $batch_info;
}

sub get_batch_script_pre_string {
  my $script_dir = shift(@_);
  my $out_dir = shift(@_);
  return "#!/bin/sh\n#\$ -S /bin/sh\n#\$ -o ${out_dir}\n#\$ -e ${out_dir}\ncd ${script_dir}\n"
}

sub make_single_batch {
  my $temp_dir = shift(@_);
  my $script_id = shift(@_);
  my $script_cmd = shift(@_);
  my $batch_info = get_empty_batch_info();
  my ($scriptfile, $keyfile);
  my $fh;
  $scriptfile = "single_${script_id}.sh";
  $keyfile = "${temp_dir}/single_${script_id}_ready";
  open $fh, "> $scriptfile" || die "Could not open $scriptfile";
  print $fh get_batch_script_pre_string($temp_dir, $temp_dir);
  print $fh $script_cmd."\n";
  print $fh "touch $keyfile\n";
  close($fh);
  push @{$batch_info->{"script"}}, $scriptfile;
  push @{$batch_info->{"key"}}, $keyfile;
  return $batch_info;
}

sub submit_and_wait {
  my $batch_info = shift(@_);
  my $batch_check_interval = shift(@_); # In seconds
  $batch_check_interval = 100 if (!(defined $batch_check_interval));

  for my $i (0..scalar @{$batch_info->{"key"}}-1) {
    system("rm ".${$batch_info->{"key"}}[$i]) if (-e ${$batch_info->{"key"}}[$i]);
  }

  for my $i (0..scalar @{$batch_info->{"script"}}-1) {
    my $qsub_command = "qsub ".$batch_info->{"qsub_options"}." ".${$batch_info->{"script"}}[$i];
    system("chmod u+x ".${$batch_info->{"script"}}[$i]);
    system("$qsub_command") && die("Error in '$qsub_command'\n");
  }
  my @sub_ready = ();
  my $ready_count = 0;
  while ($ready_count < scalar @{$batch_info->{"key"}}) {
    sleep($batch_check_interval);
    for my $i (0..scalar @{$batch_info->{"key"}}-1) {
      if (!$sub_ready[$i]) {
        if (-e ${$batch_info->{"key"}}[$i]) {
          $sub_ready[$i] = 1;
          $ready_count++;
        }
      }
    }
  }
  for my $i (0..scalar @{$batch_info->{"key"}}-1) {
    system("rm ".${$batch_info->{"key"}}[$i]);
  }
}