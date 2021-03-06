#!/usr/bin/perl
#
# Author: petr.danecek@sanger
#

use strict;
use warnings;
use Carp;
use Vcf;

my $opts = parse_params();
if ( $$opts{check_columns} )
{
    check_columns($opts);
}
elsif ( !exists($$opts{sort}) )
{
    concat($opts);
}
else
{
    concat_merge($opts);
}

exit;

#--------------------------------

sub error
{
    my (@msg) = @_;
    if ( scalar @msg )
    {
        croak @msg;
    }
    die
        "About: Convenience tool for concatenating VCF files (e.g. VCFs split by chromosome).\n",
        "   In the basic mode it does not do anything fancy except for a sanity check that all\n",
        "   files have the same columns.  When run with the -s option, it will perform a partial\n",
        "   merge sort, looking at limited number of open files simultaneously.\n",
        "Usage: vcf-concat [OPTIONS] A.vcf.gz B.vcf.gz C.vcf.gz > out.vcf\n",
        "Options:\n",
        "   -c, --check-columns              Do not concatenate, only check if the columns agree.\n",
        "   -f, --files <file>               Read the list of files from a file.\n",
        "   -p, --pad-missing                Write '.' in place of missing columns. Useful for joining chrY with the rest.\n",
        "   -s, --merge-sort <int>           Allow small overlaps in N consecutive files.\n",
        "   -h, -?, --help                   This help message.\n",
        "\n";
}

sub parse_params
{
    my $opts = { files=>[] };
    while (my $arg=shift(@ARGV))
    {
        if ( $arg eq '-p' || $arg eq '--pad-missing' ) { $$opts{pad_missing}=1; next; } 
        if ( $arg eq '-s' || $arg eq '--merge-sort' ) { $$opts{sort}=shift(@ARGV); next; } 
        if ( $arg eq '-c' || $arg eq '--check-columns' ) { $$opts{check_columns}=1; next;  }
        if ( $arg eq '-f' || $arg eq '--files' ) 
        {
            my $files = shift(@ARGV);
            open(my $fh,'<',$files) or error("$files: $!");
            while (my $line=<$fh>)
            {
                chomp($line);
                push @{$$opts{files}},$line;
            }
            close($fh);
            next;
        }
        if ( $arg eq '-?' || $arg eq '-h' || $arg eq '--help' ) { error(); }
        if ( -e $arg ) { push @{$$opts{files}},$arg; next }
        error("Unknown parameter \"$arg\". Run -h for help.\n");
    }
    if ( ! @{$$opts{files}} ) { error("No files to concat?\n") }
    return $opts;
}

sub can_be_padded
{
    my ($opts,$cols1,$cols2) = @_;
    if ( @$cols1<@$cols2 ) { error(sprintf "Not ready for this, sorry, expected fewer columns (%d!<%d)", @$cols1,@$cols2); }
    my $has1 = {};
    my $has2 = {};
    for (my $i=0; $i<@$cols1; $i++) { $$has1{$$cols1[$i]} = $i; }
    for (my $i=0; $i<@$cols2; $i++) 
    {
        if ( !exists($$has1{$$cols2[$i]}) ) { error("The column [$$cols2[$i]] not seen previously."); }
        $$has2{$$cols2[$i]} = $i; 
    }
    my @map;
    for (my $i=0; $i<@$cols1; $i++)
    {
        my $cname = $$cols1[$i];
        push @map, exists($$has2{$cname}) ? $$has2{$cname} : -1;
    }
    return \@map;
}

sub check_columns
{
    my ($opts) = @_;
    my @columns;
    for my $file (@{$$opts{files}})
    {
        my $vcf = Vcf->new(file=>$file);
        $vcf->parse_header();

        if ( @columns )
        {
            my $different_order;
            my $different_columns;
            if ( @columns != @{$$vcf{columns}} ) { warn("Different number of columns in [$file].\n"); }
            if ( $$opts{pad_missing} && can_be_padded($opts,\@columns,$$vcf{columns}) ) { next; }
            for (my $i=0; $i<@columns; $i++)
            {
                if ( $$vcf{columns}[$i] ne $columns[$i] ) 
                { 
                    if ( !exists($$vcf{has_column}{$columns[$i]}) )
                    {
                        warn("The column names do not match; the column \"$columns[$i]\" no present in [$file].\n"); 
                        $different_columns = $columns[$i];
                    }
                    elsif ( !defined $different_order )
                    {
                        $different_order = $columns[$i];
                    }
                }
            }
            if ( defined $different_order && !defined $different_columns )
            {
                warn("The columns ordered differently in [$file]. Use vcf-shuffle-cols to reorder.\n");
            }
        }
        else
        {
            @columns = @{$$vcf{columns}};
        }
        $vcf->close();
    }
}

sub concat
{
    my ($opts) = @_;
    my @columns;
    for my $file (@{$$opts{files}})
    {
        my $vcf = Vcf->new(file=>$file);
        $vcf->parse_header();

        my $map;
        if ( @columns )
        {
            if ( @columns != @{$$vcf{columns}} ) 
            { 
                if ( !$$opts{pad_missing} )
                {
                    error(sprintf "Different number of columns in [%s], expected %d, found %d\n", $file,scalar @columns,scalar @{$$vcf{columns}}); 
                }
                $map = can_be_padded($opts,\@columns,$$vcf{columns});
            }
            else
            {
                my $different_order;
                for (my $i=0; $i<@columns; $i++)
                {
                    if ( $$vcf{columns}[$i] ne $columns[$i] )
                    {
                        if ( !exists($$vcf{has_column}{$columns[$i]}) )
                        {
                            error("The column names do not match; the column \"$columns[$i]\" no present in [$file].\n");
                        }
                        elsif ( !defined $different_order )
                        {
                            $different_order = $columns[$i];
                        }
                    }
                }
                if ( defined $different_order )
                {
                    error("The columns ordered differently in [$file]. Use vcf-shuffle-cols to reorder.\n");
                }
            }
        }
        else
        {
            @columns = @{$$vcf{columns}};
            print $vcf->format_header();
        }
        while (my $line=$vcf->next_line())
        {
            if ( defined $map )
            {
                my @line = split(/\t/,$line);
                chomp($line[-1]);
                my @out;
                for my $idx (@$map)
                {
                    if ( $idx==-1 ) { push @out,'.'; }
                    else { push @out,$line[$$map[$idx]] }
                }
                print join("\t",@out),"\n";
            }
            else
            {
                print $line;
            }
        }
    }
}

sub get_chromosomes
{
    my ($files) = @_;
    my @out;
    my %has_chrm;
    for my $file (@$files)
    {
        my $vcf = Vcf->new(file=>$file);
        my $chrms = $vcf->get_chromosomes();
        for my $chr (@$chrms)
        {
            if ( exists($has_chrm{$chr}) ) { next; }
            $has_chrm{$chr} = 1;
            push @out,$chr;
        }
    }
    return \@out;
}

sub concat_merge
{
    my ($opts) = @_;

    my $header_printed = 0;
    my $chroms = get_chromosomes($$opts{files});
    for my $chr (@$chroms)
    {
        my $reader = Reader->new(files=>$$opts{files},nsort=>$$opts{sort},seq=>$chr,header_printed=>$header_printed);
        $header_printed = 1;
        $reader->open_next();
        while (1)
        {
            my $line = $reader->next_line();
            if ( !defined $line )
            {
                if ( !$reader->open_next() ) { last; }
                next;
            }
            print $line;
        }
    }
    if ( !$header_printed )
    {
        my $vcf = Vcf->new(file=>$$opts{files}[0]);
        $vcf->parse_header();
        print $vcf->format_header();
    }
}

#---------------------------------

package Reader;

use strict;
use warnings;
use Carp;
use Vcf;

sub new
{
    my ($class,@args) = @_;
    my $self = @args ? {@args} : {};
    bless $self, ref($class) || $class;
    if ( !$$self{files} ) { $self->throw("Expected the files option.\n"); }
    if ( !$$self{nsort} ) { $$self{nsort} = 2; }
    if ( $$self{nsort}>@{$$self{files}} ) { $$self{nsort} = scalar @{$$self{files}}; } 
    $$self{idxs} = undef;
    $$self{vcfs} = undef;
    return $self;
}

sub throw
{
    my ($self,@msg) = @_;
    confess @msg;
}

sub print_header
{
    my ($self,$vcf) = @_;
    if ( $$self{header_printed} ) { return; }
    print $vcf->format_header();
    $$self{header_printed} = 1;
}


# Open VCF, parse header, check column names and when callled for the first time, output the VCF header.
sub open_vcf
{
    my ($self,$file) = @_;
    my $vcf = Vcf->new(file=>$file,region=>$$self{seq},print_header=>1);
    $vcf->parse_header();
    if ( !exists($$self{columns}) )
    {
        $$self{columns} = [ @{$$vcf{columns}} ];
    }
    else
    {
        if ( @{$$self{columns}} != @{$$vcf{columns}} ) { $self->throw("Different number of columns in [$file].\n"); }
        for (my $i=0; $i<@{$$self{columns}}; $i++)
        {
            if ( $$vcf{columns}[$i] ne $$self{columns}[$i] ) { $self->throw("The column names do not agree in [$file].\n"); }
        }
    }
    $self->print_header($vcf);
    return $vcf;
}

sub open_next
{
    my ($self) = @_;

    if ( !defined $$self{idxs} )
    {
        for (my $i=0; $i<$$self{nsort}; $i++)
        {
            $$self{idxs}[$i] = $i;
        }
    }
    else
    {
        my $prev = $$self{idxs}[-1];

        shift(@{$$self{idxs}});
        shift(@{$$self{vcfs}});

        if ( $prev+1 < @{$$self{files}} ) 
        {
            # New file to be opened
            push @{$$self{idxs}}, $prev+1;
        }
    }
    for (my $i=0; $i<@{$$self{idxs}}; $i++)
    {
        if ( exists($$self{vcfs}[$i]) ) { next; }
        my $idx = $$self{idxs}[$i];
        $$self{vcfs}[$i] = $self->open_vcf($$self{files}[$idx]);
    }
    if ( !@{$$self{idxs}} ) { return 0; }
    return 1;
}

sub next_line
{
    my ($self) = @_;

    my $min = $$self{vcfs}[0]->next_line();
    if ( !defined $min ) { return undef; }

    if ( !($min=~/^(\S+)\t(\d+)/) ) { $self->throw("Could not parse the line: $min\n"); }
    my $min_chr = $1;
    my $min_pos = $2;
    my $min_vcf = $$self{vcfs}[0];

    for (my $i=1; $i<@{$$self{vcfs}}; $i++)
    {
        if ( !exists($$self{vcfs}[$i]) ) { next; }
        my $line = $$self{vcfs}[$i]->next_line();
        if ( !defined $line ) { next; }
        if ( !($line=~/^(\S+)\t(\d+)/) ) { $self->throw("Could not parse the line: $line\n"); }
        my $chr = $1;
        my $pos = $2;

        if ( $chr ne $min_chr ) { $self->throw("FIXME: When run with the -s option, only one chromosome can be present.\n"); }
        if ( $min_pos > $pos )
        {
            $min_pos = $pos;
            $min_vcf->_unread_line($min);
            $min_vcf = $$self{vcfs}[$i];
            $min = $line;
        }
        else
        {
            $$self{vcfs}[$i]->_unread_line($line);
        }
    }
    return $min;
}


