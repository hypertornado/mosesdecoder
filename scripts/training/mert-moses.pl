#!/usr/bin/perl -w
# Usage:
# mert-moses.pl <foreign> <english> <decoder-executable> <decoder-config>
# For other options see below or run 'mert-moses.pl --help'

# Notes:
# <foreign> and <english> should be raw text files, one sentence per line
# <english> can be a prefix, in which case the files are <english>0, <english>1, etc. are used

# Revision history

# 31 Jul 2006 adding default paths
# 29 Jul 2006 run-filter, score-nbest and mert run on the queue (Nicola; Ondrej had to type it in again)
# 28 Jul 2006 attempt at foolproof usage, strong checking of input validity, merged the parallel and nonparallel version (Ondrej Bojar)
# 27 Jul 2006 adding the safesystem() function to handle with process failure
# 22 Jul 2006 fixed a bug about handling relative path of configuration file (Nicola Bertoldi) 
# 21 Jul 2006 adapted for Moses-in-parallel (Nicola Bertoldi) 
# 18 Jul 2006 adapted for Moses and cleaned up (PK)
# 21 Jan 2005 unified various versions, thorough cleanup (DWC)
#             now indexing accumulated n-best list solely by feature vectors
# 14 Dec 2004 reimplemented find_threshold_points in C (NMD)
# 25 Oct 2004 Use either average or shortest (default) reference
#             length as effective reference length (DWC)
# 13 Oct 2004 Use alternative decoders (DWC)
# Original version by Philipp Koehn

# defaults for initial values and ranges are:
my $default_triples = {
  # for each _d_istortion, _l_anguage _m_odel, _t_ranslation _m_odel and _w_ord penalty, there is a list
  # of [ default value, lower bound, upper bound ]-triples. In most cases, only one triple is used,
  # but the translation model has currently 5 features
  "d" => [ [ 0.2, 0.0, 1.0 ] ],
  "lm" => [ [ 0.4, 0.0, 1.0 ] ],
  "tm" => [
            [ 0.1, 0.0, 1.0 ],
            [ 0.1, 0.0, 1.0 ],
            [ 0.1, 0.0, 1.0 ],
            [ 0.1, 0.0, 1.0 ],
            [ -1.0, -1.0, 1.0 ],
	  ],
  "g" => [ [ 0.5, 0.0, 1.0 ] ],
  "w" => [ [ 0, -0.5, 0.5 ] ],
};

# moses.ini file uses FULL names for lambdas, while this training script internally (and on the command line)
# uses ABBR names.
my $ABBR_FULL_MAP = "d=weight-d lm=weight-l tm=weight-t w=weight-w g=weight-generation";
my %ABBR2FULL = map {split/=/,$_,2} split /\s+/, $ABBR_FULL_MAP;
my %FULL2ABBR = map {my ($a, $b) = split/=/,$_,2; ($b, $a);} split /\s+/, $ABBR_FULL_MAP;

# We parse moses.ini to figure out how many weights do we need to optimize.
# For this, we must know the correspondence between options defining files
# for models and options assigning weights to these models.
my $TABLECONFIG_ABBR_MAP = "ttable-file=tm lmodel-file=lm distortion-file=d generation-file=g";
my %TABLECONFIG2ABBR = map {split(/=/,$_,2)} split /\s+/, $TABLECONFIG_ABBR_MAP;

# There are weights that do not correspond to any input file, they just increase the total number of lambdas we optimize
my $extra_lambdas_for_model = {
  "w" => 1,  # word penalty
  "d" => 1,  # basic distortion
};




my $verbose = 0;
my $usage = 0; # request for --help
my $___WORKING_DIR = "mert-work";
my $___DEV_F = undef; # required, input text to decode
my $___DEV_E = undef; # required, basename of files with references
my $___DECODER = undef; # required, pathname to the decoder executable
my $___CONFIG = undef; # required, pathname to startup ini file
my $___N_BEST_LIST_SIZE = 100;
my $___PARALLELIZER = undef;  # pathname to script that runs moses in parallel (default: run normal serial moses)
my $___PARALLELIZER_FLAGS = "";  # extra parameters for parallelizer
my $___JOBS = 10; # if parallel, number of jobs to use
my $___DECODER_FLAGS = ""; # additional parametrs to pass to the decoder
my $___LAMBDA = undef; # string specifying the seed weights and boundaries of all lambdas
my $___START_STEP = undef;  # which iteration step to start with
                  # <start-step> is what iteration to start at (default 1). If you add an 'a'
                  #   suffix the decoding for that iteration will be skipped (only cmert is run)

# Parameter for effective reference length when computing BLEU score
# This is used by score-nbest-bleu.py
# Default is to use shortest reference
# Use "--average" to use average reference length
my $___AVERAGE = 0;

my $SCRIPTS_ROOTDIR = undef; # path to all tools (overriden by specific options)
my $cmertdir = undef; # path to cmert directory
my $pythonpath = undef; # path to python libraries needed by cmert
my $filtercmd = undef; # path to filter-model-given-input.pl
my $SCORENBESTCMD = undef;
my $qsubwrapper = undef;


use strict;
use Getopt::Long;
GetOptions(
  "working-dir=s" => \$___WORKING_DIR,
  "input=s" => \$___DEV_F,
  "refs=s" => \$___DEV_E,
  "decoder=s" => \$___DECODER,
  "config=s" => \$___CONFIG,
  "nbest=i" => \$___N_BEST_LIST_SIZE,
  "parallelizer=s" => \$___PARALLELIZER,
  "parallelizer-flags=s" => \$___PARALLELIZER_FLAGS,
  "jobs=i" => \$___JOBS,
  "decoder-flags=s" => \$___DECODER_FLAGS,
  "lambdas=s" => \$___LAMBDA,
  "start-step=i" => \$___START_STEP,
  "average" => \$___AVERAGE,
  "help" => \$usage,
  "verbose" => \$verbose,
  "roodir=s" => \$SCRIPTS_ROOTDIR,
  "cmertdir=s" => \$cmertdir,
  "pythonpath=s" => \$pythonpath,
  "filtercmd=s" => \$filtercmd, # allow to override the default location
  "scorenbestcmd=s" => \$SCORENBESTCMD, # path to score-nbest.py
  "qsubwrapper=s" => \$qsubwrapper, # allow to override the default location
);

# the 4 required parameters can be supplied on the command line directly
# or using the --options
if (scalar @ARGV == 4) {
  # required parameters: input_file references_basename decoder_executable
  $___DEV_F = shift;
  $___DEV_E = shift;
  $___DECODER = shift;
  $___CONFIG = shift;
}

if ($usage || !defined $___DEV_F || !defined$___DEV_E || !defined$___DECODER || !defined $___CONFIG) {
  print STDERR "usage: mert-moses.pl input-text references decoder-executable decoder.ini
Options:
  --working-dir=mert-dir ... where all the files are created
  --nbest=100 ... how big nbestlist to generate
  --parallelizer=script  ... optional path to moses-parallel.perl
  --parallelizer-flags=STRING  ... anything you with to pass to 
              parallelizer, eg. '-qsub-prefix logname'
  --decoder-flags=STRING ... extra parameters for the decoder
  --lambdas=STRING  ... default values and ranges for lambdas, a complex string
         such as 'd:1,0.5-1.5 lm:1,0.5-1.5 tm:0.3,0.25-0.75;0.2,0.25-0.75;0.2,0.25-0.75;0.3,0.25-0.75;0,-0.5-0.5 w:0,-0.5-0.5'
  --start-step=NUM  ... start at step X (that has been already achieved before)
  --average   ... Use either average or shortest (default) reference
                  length as effective reference length
  --filtercmd=STRING  ... path to filter-model-given-input.pl
  --roodir=STRING  ... where do helpers reside (if not given explicitly)
  --cmertdir=STRING ... where is cmert installed
  --pythonpath=STRING  ... where is python executable
  --scorenbestcmd=STRING  ... path to score-nbest.py
";
  exit 1;
}

# Check validity of input parameters




if (!defined $SCRIPTS_ROOTDIR) {
  $SCRIPTS_ROOTDIR = $ENV{"SCRIPTS_ROOTDIR"};
  die "Please set SCRIPTS_ROOTDIR or specify --rootdir" if !defined $SCRIPTS_ROOTDIR;
}

print STDERR "Using SCRIPTS_ROOTDIR: $SCRIPTS_ROOTDIR\n";




# path of script for filtering phrase tables and running the decoder
$filtercmd="$SCRIPTS_ROOTDIR/training/filter-model-given-input.pl" if !defined $filtercmd;

$qsubwrapper="$SCRIPTS_ROOTDIR/training/qsub-wrapper.pl" if !defined $qsubwrapper;


$cmertdir = "$SCRIPTS_ROOTDIR/extra/cmert-0.5" if !defined $cmertdir;
my $cmertcmd="$cmertdir/mert";

$SCORENBESTCMD = "$cmertdir/score-nbest.py" if ! defined $SCORENBESTCMD;

$pythonpath = "$cmertdir/python" if !defined $pythonpath;

$ENV{PYTHONPATH} = $pythonpath; # other scripts need to know


die "Not executable: $filtercmd" if ! -x $filtercmd;
die "Not executable: $cmertcmd" if ! -x $cmertcmd;
die "Not a dir: $pythonpath" if ! -d $pythonpath;
die "Not executable: $___DECODER" if ! -x $___DECODER;

my $input_abs = ensure_full_path($___DEV_F);
die "File not found: $___DEV_F (interpreted as $input_abs)."
  if ! -e $input_abs;
$___DEV_F = $input_abs;


my $decoder_abs = ensure_full_path($___DECODER);
die "File not found: $___DECODER (interpreted as $decoder_abs)."
  if ! -x $decoder_abs;
$___DECODER = $decoder_abs;


my $ref_abs = ensure_full_path($___DEV_E);
# check if English dev set (reference translations) exist and store a list of all references
my @references;
if (-e $ref_abs) {
  push @references, $ref_abs;
}
else {
  # if multiple file, get a full list of the files
    my $part = 0;
    while (-e $ref_abs.$part) {
        push @references, $ref_abs.$part;
        $part++;
    }
    die("Reference translations not found: $___DEV_E (interpreted as $ref_abs)") unless $part;
}

my $config_abs = ensure_full_path($___CONFIG);
die "File not found: $___CONFIG (interpreted as $config_abs)."
  if ! -e $config_abs;
$___CONFIG = $config_abs;



# check validity of moses.ini and collect number of models and lambdas per model
# need to make a copy of $extra_lambdas_for_model, scan_config spoils it
my %copy_of_extra_lambdas_for_model = %$extra_lambdas_for_model;
my ($lambdas_per_model, $models_used) = scan_config($___CONFIG, \%copy_of_extra_lambdas_for_model);


# Parse the lambda config string and convert it to a nice structure in the same format as $default_triples
my $use_triples = undef;
if (defined $___LAMBDA) {
  # interpreting lambdas from command line
  foreach (split(/\s+/,$___LAMBDA)) {
      my ($name,$values) = split(/:/);
      die "Malformed setting: '$_', expected name:values\n" if !defined $name || !defined $values;
      foreach my $startminmax (split/;/,$values) {
	  if ($startminmax =~ /^(-?[\.\d]+),(-?[\.\d]+)-(-?[\.\d]+)$/) {
	      my $start = $1;
	      my $min = $1;
	      my $max = $1;
              push @{$use_triples->{$name}}, [$start, $min, $max];
	  }
	  else {
	      die "Malformed feature range definition: $name => $startminmax\n";
	  }
      } 
  }
} else {
  # no lambdas supplied, use the default ones, but do not forget to repeat them accordingly
  # first for or inherent models
  foreach my $name (keys %$extra_lambdas_for_model) {
    foreach (1..$extra_lambdas_for_model->{$name}) {
      die "No default weights defined for -$name"
        if !defined $default_triples->{$name};
      push @{$use_triples->{$name}}, @{$default_triples->{$name}};
    }
  }
  # and then for all models used
  foreach my $name (keys %$models_used) {
    foreach (1..$models_used->{$name}) {
      die "No default weights defined for -$name"
        if !defined $default_triples->{$name};
      push @{$use_triples->{$name}}, @{$default_triples->{$name}};
    }
  }
}

# moses should use our config
if ($___DECODER_FLAGS =~ /(^|\s)-(config|f) /
|| $___DECODER_FLAGS =~ /(^|\s)-(ttable-file|t) /
|| $___DECODER_FLAGS =~ /(^|\s)-(distortion-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(generation-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(lmodel-file) /
) {
  die "It is forbidden to supply any of -config, -ttable-file, -distortion-file, -generation-file or -lmodel-file in the --decoder-flags.\nPlease use only the --config option to give the config file that lists all the supplementary files.";
}

# convert the lambda triples to independent streams of default lambdas, minimums, maximums, names and a random seed generator
my @LAMBDA = ();   # the starting values
my @MIN = ();   # lower bounds
my @MAX = ();   # upper bounds
my @NAME = ();  # to which model does the lambda belong
my $rand = "";
my $decoder_config = "";

# this loop actually does the conversion and also checks for
# the match in lambda count
foreach my $name (keys %$use_triples) {
  $decoder_config .= "-$name ";
  my $expected_lambdas = $lambdas_per_model->{$name};
  $expected_lambdas = 0 if !defined $expected_lambdas;
  my $got_lambdas = defined $use_triples->{$name} ? scalar @{$use_triples->{$name}}  : 0;
  die "Wrong number of lambdas for $name. Expected (given the config file): $expected_lambdas, got: $got_lambdas"
    if $got_lambdas != $expected_lambdas;
  
  foreach my $feature (@{$use_triples->{$name}}) {
    my ($startval, $min, $max) = @$feature;
    push @LAMBDA, $startval;
    push @MIN, $min;
    push @MAX, $max;
    push @NAME, $name;
    $decoder_config .= "%.6f ";
    $rand .= "$min+rand(".($max-$min)."), ";
  }
}

# print the real config
print STDERR "DECODER_CFG: $decoder_config\n";

# as weights are normalized in the next steps (by cmert)

# normalize initial LAMBDAs, too
my $totlambda=0;
grep($totlambda+=abs($_),@LAMBDA);
grep($_/=$totlambda,@LAMBDA);




# set start run, if specified (allow the user to skip some of the iterations using --start-step)
my $start_run = 1;
my $skip_decoder = 0; # skip the decoder run for the first time
if (defined $___START_STEP) {
  $start_run = $___START_STEP;
  $skip_decoder = 1;
}

#store current directory and create the working directory (if needed)
my $cwd = `pwd`; chop($cwd);
safesystem("mkdir -p $___WORKING_DIR") or die "Can't mkdir $___WORKING_DIR";

#chdir to the working directory
chdir($___WORKING_DIR) or die "Can't chdir to $___WORKING_DIR";




# create some initial files (esp. weights and their ranges for randomization)

open(WEIGHTS,"> weights.txt") or die "Can't write weights.txt (WD now $___WORKING_DIR)";
print WEIGHTS join(" ", @LAMBDA)."\n";
close(WEIGHTS);

open(RANGES,"> ranges.txt") or die "Can't write weights.txt (WD now $___WORKING_DIR)";
print RANGES join(" ", @MIN)."\n";
print RANGES join(" ", @MAX)."\n";
close(RANGES);


# filter the phrase tables, use --decoder-flags
print "filtering the phrase tables... ".`date`;
my $cmd = "$filtercmd ./filtered $___CONFIG $___DEV_F";
safesystem("$qsubwrapper -command='$cmd'") or die "Failed to submit filtering of tables to the queue (via $qsubwrapper)";


# the decoder should now use the filtered model
my $PARAMETERS;
$PARAMETERS = $___DECODER_FLAGS . " -config filtered/moses.ini";

my $devbleu;
my $run=$start_run-1;
my $prev_size = -1;
while(1) {
  $run++;
  # run beamdecoder with option to output nbestlists
  # the end result should be (1) @NBEST_LIST, a list of lists; (2) @SCORE, a list of lists of lists

  print "run $run start at ".`date`;

  # get most recent set of weights
  open(WEIGHTS,"< weights.txt") or die "Can't read weights";
  while(<WEIGHTS>) {
      chomp;
      @LAMBDA = split " ";
  }
  close(WEIGHTS);

  # In case something dies later, we might wish to have a copy
  create_config($___CONFIG, "./run$run.moses.ini", \@LAMBDA, \@NAME, $run, (defined$devbleu?$devbleu:"--not-estimated--"));


  # skip if restarted
  if (!$skip_decoder) {
      print "($run) run decoder to produce n-best lists\n";
      print "LAMBDAS are @LAMBDA\n";
      run_decoder(\@LAMBDA);
      safesystem("gzip -f run*out") or die "Failed to gzip run*out";
  }
  else {
      print "skipped decoder run\n";
      $skip_decoder = 0;
  }

  my $EFF_REF_LEN = "";
  if ($___AVERAGE) {
     $EFF_REF_LEN = "-a";
  }

  # To be sure that scoring script produses these fresh:
  safesystem("rm -f cands.opt feats.opt") or die;

  # convert n-best list into a numberized format with error scores

  print STDERR "Scoring the nbestlist.\n";
  my $cmd = "export PYTHONPATH=$pythonpath ; gunzip -dc run*.best*.out.gz | sort -n -t \"|\" -k 1,1 | $SCORENBESTCMD $EFF_REF_LEN ".join(" ", @references)." ./";
  safesystem("$qsubwrapper -command='$cmd'") or die "Failed to submit scoring nbestlist to queue (via $qsubwrapper)";


  print STDERR "Hoping that scoring succeeded. Don't know how to check for it! XXX.\n";


  # keep a count of lines in nbests lists (alltogether)
  # if it did not increase since last iteration, we are DONE
  open(IN,"cands.opt") or die "Can't read cands.opt";
  my $size=0;
  while (<IN>) {
    chomp;
    my @flds = split / /;
    $size += $flds[1];
  }
  close(IN);
  print "$size accumulated translations\n";
  print "prev accumulated translations was : $prev_size\n";
  if ($size <= $prev_size){
     print "Training finished at ".`date`;
     last;
  }
  $prev_size = $size;


  # run cmert
  safesystem("cat ranges.txt weights.txt > init.opt") or die;
  safesystem("mv weights.txt run$run.input_weights.txt") or die; # keep a copy of the weights

  #store actual values
  safesystem("cp init.opt run$run.init.opt") or die;

  my $DIM = scalar(@LAMBDA); # number of lambdas
  $cmd="$cmertcmd -d $DIM";
 
  print STDERR "Starting cmert.\n";
  safesystem("$qsubwrapper -command='$cmd' -stderr=cmert.log") or die "Failed to start cmert (via qsubwrapper $qsubwrapper)";

  my $bestpoint = undef;
  my $devbleu = undef;
  open(IN,"cmert.log") or die "Can't open cmert.log";
  while (<IN>) {
    if (/(Best point: [\s\d\.\-]+ => )([\d\.]+)/) {
      $bestpoint = $1;
      $devbleu = $2;
      last;
    }
  }
  close IN;
  die "Failed to parse cmert.log, missed Best point there."
    if !defined $bestpoint || !defined $devbleu;
  print "($run) BEST at $run: $bestpoint$devbleu at ".`date`;
  
  safesystem ("cp cmert.log run$run.cmert.log") or die;

  print "run $run end at ".`date`;

  if (! -s "weights.txt"){
      die "Optimization failed, file weights.txt does not exist or is empty";
  }
}
safesystem("cp init.opt run$run.init.opt") or die;
safesystem ("cp cmert.log run$run.cmert.log") or die;

# the current weights are read at the beginning of each loop, so
# @LAMBDA contain the weights before the last run of the decoder.
# This is fine, because the new attempt did not bring any improvement,
# so we do not want to use it.
# @NAME are the names of models the lambdas belong to
create_config($___CONFIG, "./moses.ini", \@LAMBDA, \@NAME, $run, $devbleu);

#chdir back to the original directory # useless, just to remind we were not there
chdir($cwd);

sub run_decoder {
    my ($LAMBDA) = @_;
    my $filename_template = "run%d.best$___N_BEST_LIST_SIZE.out";
    my $filename = sprintf($filename_template, $run);
    
    print "params = $PARAMETERS\n";
    my $decoder_config = sprintf($decoder_config,@{$LAMBDA});
    print "decoder_config = $decoder_config\n";

    # run the decoder
    my $decoder_cmd;
    if (defined $___PARALLELIZER) {
      $decoder_cmd = "$___PARALLELIZER $___PARALLELIZER_FLAGS $PARAMETERS $decoder_config -n-best-file $filename -n-best-size $___N_BEST_LIST_SIZE -i $___DEV_F -jobs $___JOBS -decoder $___DECODER > run$run.out";
    } else {
      $decoder_cmd = "$___DECODER $PARAMETERS $decoder_config -n-best-list $filename $___N_BEST_LIST_SIZE -i $___DEV_F > run$run.out";
    }

    safesystem($decoder_cmd) or die "The decoder died.";
}

sub create_config {
    my $infn = shift; # source config
    my $outfn = shift; # where to save the config
    my $lambdas = shift; # the lambdas we should write
    my @lambdas = @$lambdas; # my own copy of the array
    my $names = shift; # the names of the lambdas
    my @names = @$names; # my own copy of the array
    my $run = shift;  # just for verbosity
    my $devbleu = shift; # just for verbosity

    my %P; # the hash of all parameters we wish to override

    # first convert the command line parameters to the hash
    { # ensure local scope of vars
	my $parameter=undef;
	print "Parsing --decoder-flags: |$___DECODER_FLAGS|\n";
        $___DECODER_FLAGS =~ s/^\s*|\s*$//;
        $___DECODER_FLAGS =~ s/\s+/ /;
	foreach (split(/ /,$___DECODER_FLAGS)) {
	    if (/^\-([^\d].*)$/) {
		$parameter = $1;
		$parameter = $ABBR2FULL{$parameter} if defined($ABBR2FULL{$parameter});
	    }
	    else {
                die "Found value with no -paramname before it: $_"
                  if !defined $parameter;
		push @{$P{$parameter}},$_;
	    }
	}
    }

    # Convert weights to elements in P
    # First delete all weights params from the input
    foreach my $abbr (@names) {
      my $name = defined $ABBR2FULL{$abbr} ? $ABBR2FULL{$abbr} : $abbr;
      delete($P{$name});
    }
    while (my $abbr = shift @names) {
      my $w = shift @lambdas;
      die "Lambdas and names do not have equal length!" if !defined $w;
      my $name = defined $ABBR2FULL{$abbr} ? $ABBR2FULL{$abbr} : $abbr;
      push @{$P{$name}}, $w;
    }


    # create new moses.ini decoder config file by cloning and overriding the original one
    open(INI,$infn) or die "Can't read $infn";
    delete($P{"config"}); # never output 
    print "Saving new config to: $outfn";
    open(OUT,"> $outfn") or die "Can't write $outfn";
    print OUT "# MERT optimized configuration\n";
    print OUT "# decoder $___DECODER\n";
    print OUT "# BLEU $devbleu on dev $___DEV_F\n";
    print OUT "# $run iterations\n";
    print OUT "# finished ".`date`;
    my $line = <INI>;
    while(1) {
	last unless $line;

	# skip until hit [parameter]
	if ($line !~ /^\[(.+)\]\s*$/) { 
	    $line = <INI>;
	    print OUT $line if $line =~ /^\#/ || $line =~ /^\s+$/;
	    next;
	}

	# parameter name
	my $parameter = $1;
	$parameter = $ABBR2FULL{$parameter} if defined($ABBR2FULL{$parameter});
	print OUT "[$parameter]\n";

	# change parameter, if new values
	if (defined($P{$parameter})) {
	    # write new values
	    foreach (@{$P{$parameter}}) {
		print OUT $_."\n";
	    }
	    delete($P{$parameter});
	    # skip until new parameter, only write comments
	    while($line = <INI>) {
		print OUT $line if $line =~ /^\#/ || $line =~ /^\s+$/;
		last if $line =~ /^\[/;
		last unless $line;
	    }
	    next;
	}
	
	# unchanged parameter, write old
	while($line = <INI>) {
	    last if $line =~ /^\[/;
	    print OUT $line;
	}
    }

    # write all additional parameters
    foreach my $parameter (keys %P) {
	print OUT "\n[$parameter]\n";
	foreach (@{$P{$parameter}}) {
	    print OUT $_."\n";
	}
    }

    close(INI);
    close(OUT);
    print STDERR "Saved: $outfn\n";
}

sub safesystem {
  print STDERR "Executing: @_\n";
  system(@_);
  if ($? == -1) {
      print STDERR "Failed to execute: @_\n  $!\n";
      exit(1);
  }
  elsif ($? & 127) {
      printf STDERR "Execution of: @_\n  died with signal %d, %s coredump\n",
          ($? & 127),  ($? & 128) ? 'with' : 'without';
      exit(1);
  }
  else {
    my $exitcode = $? >> 8;
    print STDERR "Exit code: $exitcode\n" if $exitcode;
    return ! $exitcode;
  }
}
sub ensure_full_path {
    my $PATH = shift;
    return $PATH if $PATH =~ /^\//;
    $PATH = `pwd`."/".$PATH;
    $PATH =~ s/[\r\n]//g;
    $PATH =~ s/\/\.\//\//g;
    $PATH =~ s/\/+/\//g;
    my $sanity = 0;
    while($PATH =~ /\/\.\.\// && $sanity++<10) {
        $PATH =~ s/\/+/\//g;
        $PATH =~ s/\/[^\/]+\/\.\.\//\//g;
    }
    $PATH =~ s/\/[^\/]+\/\.\.$//;
    $PATH =~ s/\/+$//;
    return $PATH;
}




sub scan_config {
  my $ini = shift;
  my $inishortname = $ini; $inishortname =~ s/^.*\///; # for error reporting
  my $lambda_counts = shift;
  # we get a pre-filled counts, because some lambdas are always needed (word penalty, for instance)
  # as we walk though the ini file, we record how many extra lambdas do we need
  # and finally, we report it

  # in which field (counting from zero) is the filename to check?
  my %where_is_filename = (
    "ttable-file" => 3,
    "generation-file" => 2,
    "lmodel-file" => 3,
    "distortion-file" => 0,
  );
  # by default, each line of each section means one lambda, but some sections
  # explicitly state a custom number of lambdas
  my %where_is_lambda_count = (
    "ttable-file" => 2,
  );
  
  open INI, $ini or die "Can't read $ini";
  my $section = undef;  # name of the section we are reading
  my $shortname = undef;  # the corresponding short name
  my $nr = 0;
  my $error = 0;
  my %defined_files;
  my %defined_steps;  # check the ini file for compatible mapping steps and actually defined files
  while (<INI>) {
    $nr++;
    next if /^\s*#/; # skip comments
    if (/^\[([^\]]*)\]\s*$/) {
      $section = $1;
      $shortname = $TABLECONFIG2ABBR{$section};
      next;
    }
    if (defined $section && $section eq "mapping") {
      # keep track of mapping steps used
      $defined_steps{$1}++ if /^([TG])/;
    }
    if (defined $section && defined $where_is_filename{$section}) {
      # this ini section is relevant to lambdas
      chomp;
      my @flds = split / +/;
      my $fn = $flds[$where_is_filename{$section}];
      if (defined $fn && $fn !~ /^\s+$/) {
        # this is a filename! check it
	if ($fn !~ /^\//) {
	  $error = 1;
	  print STDERR "$inishortname:$nr:Filename not absolute: $fn\n";
	}
	if (! -s $fn) {
	  $error = 1;
	  print STDERR "$inishortname:$nr:File does not exist or empty: $fn\n";
	}
	# remember the number of files used, to know how many lambdas do we need
        die "No short name was defined for section $section!"
          if ! defined $shortname;

        # how many lambdas does this model need?
        # either specified explicitly, or the default, i.e. one
        my $needlambdas = defined $where_is_lambda_count{$section} ? $flds[$where_is_lambda_count{$section}] : 1;

        print STDERR "Config needs $needlambdas lambdas for $section (i.e. $shortname)\n" if $verbose;
	$lambda_counts->{$shortname}+=$needlambdas;
        if (!defined $___LAMBDA && (!defined $default_triples->{$shortname} || scalar(@{$default_triples->{$shortname}}) != $needlambdas)) {
          print STDERR "$inishortname:$nr:Your model $shortname needs $needlambdas weights but we define the default ranges for "
            .scalar(@{$default_triples->{$shortname}})." weights. Cannot use the default, you must supply lambdas by hand.\n";
          $error = 1;
        }
        $defined_files{$shortname}++;
      }
    }
  }
  die "$inishortname: File was empty!" if !$nr;
  close INI;
  for my $pair (qw/T=tm=translation G=g=generation/) {
    my ($tg, $shortname, $label) = split /=/, $pair;
    $defined_files{$shortname} = 0 if ! defined $defined_files{$shortname};
    $defined_steps{$tg} = 0 if ! defined $defined_steps{$tg};
    if ($defined_files{$shortname} != $defined_steps{$tg}) {
      print STDERR "$inishortname: You defined $defined_files{$shortname} files for $label but use $defined_steps{$tg} in [mapping]!\n";
      $error = 1;
    }
  }
  exit(1) if $error;
  return ($lambda_counts, \%defined_files);
}

