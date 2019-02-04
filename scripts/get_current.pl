#!/usr/bin/env perl

use warnings;
use strict;

my $pythonpath = "/Users/simongladman/miniconda3/envs/galaxy_training_material/bin/python";
my $get_tools_command = "/Users/simongladman/miniconda3/envs/galaxy_training_material/bin/get-tool-list";
my $apikey_file = "/Users/simongladman/.ssh/apikeys.txt";

my %apikeys;

unless(open IN, $apikey_file){ die "Couldn't find $apikey_file\n$!"; }

while(<IN>){
    chomp;
    my @tmp = split /\s+/, $_;
    print "$tmp[0] $tmp[1]\n";
    $apikeys{$tmp[0]} = $tmp[1];
}

foreach my $serv (keys %apikeys){

    print "Working on tool lists from server: $serv\n";
    my $outfile = $serv;
    $outfile =~ s/https:\/\///;
    $outfile =~ s/.genome.edu.au//;
    #print "$outfile\n";

    system("$pythonpath $get_tools_command -g $serv --get_data_managers --include_tool_panel_id -a $apikeys{$serv} -o $outfile.yml") == 0 or die { print "Failed at getting tools for $serv\n$!" };

    system("$pythonpath scripts/split_tool_yml.py -i $outfile.yml -o $outfile") == 0 or die { print "Failed at splitting tools for $serv\n$!" };

    unlink "$outfile.yml"

}
