package Bio::Graphics::Browser;
# $Id: Browser.pm,v 1.13 2002-03-24 04:29:44 lstein Exp $

use strict;
use File::Basename 'basename';
use Bio::Graphics;
use Carp qw(carp croak);
use GD 'gdMediumBoldFont';
use CGI qw(img param Delete_all url);
use Digest::MD5 'md5_hex';
use File::Path 'mkpath';

require Exporter;

use constant DEFAULT_WIDTH => 800;
use vars '$VERSION','@ISA','@EXPORT';
$VERSION = '1.10';

@ISA    = 'Exporter';
@EXPORT = 'commas';

sub new {
  my $class    = shift;
  my $self = bless { },ref($class) || $class;
  $self;
}

sub sources {
  my $self = shift;
  my $conf = $self->{conf} or return;
  return keys %$conf;
}

# get/set current source (not sure if this is wanted)
sub source {
  my $self = shift;
  my $d = $self->{source};
  if (@_) {
    my $source = shift;
    unless ($self->{conf}{$source}) {
      carp("invalid source: $source");
      return $d;
    }
    $self->{source} = $source;
  }
  $d;
}

# get Bio::DB::GFF settings
sub dbgff_settings {
  my $self = shift;

  my $dsn     = $self->setting('database') or croak "No database defined in ",$self->source;
  my $adaptor = $self->setting('adaptor') || 'dbi::mysqlopt';
  my @argv = (-adaptor => $adaptor,
	      -dsn     => $dsn);
  if (my $fasta = $self->setting('fasta_files')) {
    push @argv,(-fasta=>$fasta);
  }
  if (my $user = $self->setting('user')) {
    push @argv,(-user=>$user);
  }
  if (my $pass = $self->setting('pass')) {
    push @argv,(-pass=>$pass);
  }
  if (my @aggregators = split /\s+/,$self->setting('aggregators')) {
    push @argv,(-aggregator => \@aggregators);
  }
  @argv;
}

sub setting {
  my $self = shift;
  unshift @_,'general' if @_ == 1;
  $self->config->setting(@_);
}

sub citation {
  my $self = shift;
  my $label = shift;
  $self->config->setting($label=>'citation');
}

sub description {
  my $self = shift;
  my $source = shift;
  my $c = $self->{conf}{$source}{data} or return;
  return $c->setting('general','description');
}

sub config {
  my $self = shift;
  my $source = $self->source;
  $self->{conf}{$source}{data};
}

sub default_labels {
  my $self = shift;
  $self->config->default_labels;
}

sub default_label_indexes {
  my $self = shift;
  $self->config->default_label_indexes;
}

sub feature2label {
  my $self = shift;
  my $feature = shift;
  return $self->config->feature2label($feature);
}

sub make_link {
  my $self = shift;
  my $feature = shift;
  return $self->config->make_link($feature);
}

sub labels {
  my $self = shift;
  my $order = shift;
  my @labels = $self->config->labels;
  if ($order) { # custom order
    return @labels[@$order];
  } else {
    return @labels;
  }
}

sub width {
  my $self = shift;
  my $d = $self->{width};
  $self->{width} = shift if @_;
  $d;
}

sub header {
  my $self = shift;
  my $header = $self->config->code_setting(general => 'header');
  return $header->(@_) if ref $header eq 'CODE';
  return $header;
}

sub footer {
  my $self = shift;
  my $footer = $self->config->code_setting(general => 'footer');
  return $footer->(@_) if ref $footer eq 'CODE';
  return $footer;
}

sub render_html {
  my $self = shift;
  my %args = @_;

  my $segment         = $args{segment};
  my $feature_files   = $args{feature_files};
  my $options         = $args{options};
  my $tracks          = $args{tracks};
  my $do_map          = $args{do_map};
  my $do_centering_map= $args{do_centering_map};

  return unless $segment;

  my($image,$map) = $self->image_and_map(segment       => $segment,
					 feature_files => $feature_files,
					 options       => $options,
					 tracks        => $tracks,
					);

  my ($width,$height) = $image->getBounds;
  my @mtimes = map {ref($_) && $_->mtime} values %$feature_files;

  local $^W = 0;
  my $signature = md5_hex($segment,
			  (map {$_||0} @{$tracks||[]}),
			  $self->{width},
			  $self->source || '',
			  @mtimes,
			  ref($options) && %{$options}
			 );
  my $url     = $self->generate_image($image,$signature);
  my $img     = img({-src=>$url,-align=>'CENTER',-usemap=>'#hmap',-width => $width,-height => $height,-border=>0});
  my $img_map = $self->make_map($map,$do_centering_map) if $do_map;
  return wantarray ? ($img,$img_map) : join "<br>",$img,$img_map;
}

sub generate_image {
  my $self = shift;
  my ($image,$signature) = @_;
  my $extension = $image->can('png') ? 'png' : 'gif';
  my ($uri,$path) = $self->tmpdir($self->source.'/img');
  my $url         = sprintf("%s/%s.%s",$uri,$signature,$extension);
  my $imagefile   = sprintf("%s/%s.%s",$path,$signature,$extension);
  open (F,">$imagefile") || die("Can't open image file $imagefile for writing: $!\n");
  print F $image->can('png') ? $image->png : $image->gif;
  close F;
  return $url;
}

sub tmpdir {
  my $self = shift;

  my $path = shift || '';
  my $tmpuri = $self->setting('tmpimages') or die "no tmpimages option defined, can't generate a picture";
  $tmpuri .= "/$path" if $path;
  my $tmpdir;
  if ($ENV{MOD_PERL}) {
    my $r          = Apache->request;
    my $subr       = $r->lookup_uri($tmpuri);
    $tmpdir        = $subr->filename;
    my $path_info  = $subr->path_info;
    $tmpdir       .= $path_info if $path_info;
  } else {
    $tmpdir = "$ENV{DOCUMENT_ROOT}/$tmpuri";
  }
  mkpath($tmpdir,0,0777) unless -d $tmpdir;
  return ($tmpuri,$tmpdir);
}

sub make_map {
  my $self = shift;
  my $boxes = shift;
  my $centering_map = shift;

  my $map = qq(<map name="hmap">\n);

  # use the scale as a centering mechanism
  my $ruler = shift @$boxes;
  $map .= $self->make_centering_map($ruler) if $centering_map;

  foreach (@$boxes){
    next unless $_->[0]->can('primary_tag');
    my $href  = $self->make_href($_->[0]) or next;
    my $alt   = $self->make_alt($_->[0]);
    $map .= qq(<AREA SHAPE="RECT" COORDS="$_->[1],$_->[2],$_->[3],$_->[4]" 
	       HREF="$href" ALT="$alt" TITLE="$alt">\n);
  }
  $map .= "</map>\n";
  $map;
}

# this one is scary because it messes with CGI parameters
sub make_centering_map {
  my $self = shift;
  my $ruler = shift;
  return if $ruler->[3]-$ruler->[1] == 0;

  my $offset = $ruler->[0]->start;
  my $scale  = $ruler->[0]->length/($ruler->[3]-$ruler->[1]);

  # divide into ten intervals
  my $portion = ($ruler->[3]-$ruler->[1])/10;
  Delete_all();
  param(ref => scalar($ruler->[0]->ref));

  my @lines;
  for my $i (0..19) {
    my $x1 = $portion * $i;
    my $x2 = $portion * ($i+1);
    # put the middle of the sequence range into the middle of the picture
    my $middle = $offset + $scale * ($x1+$x2)/2;
    my $start  = int($middle - $ruler->[0]->length/2);
    my $stop   = int($start + $ruler->[0]->length - 1);
    param(start => int($start));
    param(stop  => int($stop));
    param(nav4  => 1);
    param(source=> $self->source);
    my $url = url(-relative=>1,-query=>1,-path_info=>1);
    push @lines,
      qq(<AREA SHAPE="RECT" COORDS="$x1,$ruler->[2],$x2,$ruler->[4]"
	 HREF="$url" ALT="center" TITLE="center">\n);
  }
  return join '',@lines;
}

sub make_href {
  my $self = shift;
  my $feature = shift;

  if ($feature->can('make_link')) {
    return $feature->make_link;
  } else {
    return $self->make_link($feature);
  }
}

sub make_alt {
  my $slef    = shift;
  my $feature = shift;

  my $label = $feature->class .":".$feature->info;
  if ($feature->method =~ /^(similarity|alignment)$/) {
    $label .= " ".commas($feature->target->start)."..".commas($feature->target->end);
  } else {
    $label .= " ".commas($feature->start)."..".commas($feature->stop);
  }
  return $label;
}

# Generate the image and the box list, and return as a two-element list.
# arguments: a key=>value list
#    'segment'       A feature iterator that responds to next_seq() methods
#    'feature_files' A hash of Bio::Graphics::FeatureFile objects containing 3d party features
#    'options'       An hashref of options, where 0=auto, 1=force no bump, 2=force bump, 3=force label
#    'tracks'        List of named tracks, in the order in which they are to be shown
sub image_and_map {
  my $self    = shift;
  my %config  = @_;

  my $segment       = $config{segment};
  my $feature_files = $config{feature_files} || {};
  my $tracks        = $config{tracks}        || [];
  my $options       = $config{options}       || {};

  # these are natively configured tracks
  my @labels = $self->labels;

  my $width = $self->width;
  my $conf  = $self->config;
  my $max_labels = $conf->setting(general=>'label density') || 10;
  my $max_bump   = $conf->setting(general=>'bump density')  || 50;
  my $lowres     = ($conf->setting(general=>'low res')||0) <= $segment->length;

  my @feature_types = map {$conf->label2type($_,$lowres)} @$tracks;

  # Create the tracks that we will need
  my $panel = Bio::Graphics::Panel->new(-segment => $segment,
					-width   => $width,
					-keycolor => 'moccasin',
					-grid => 1,
				       );
  $panel->add_track($segment   => 'arrow',
		    -double => 1,
		    -tick=>2,
		   );

  my (%tracks,@blank_tracks);

  for (my $i= 0; $i < @$tracks; $i++) {

    my $label = $tracks->[$i];

    # if we don't have a built-in label, then this is a third party annotation
    if (my $ff = $feature_files->{$label}) {
      push @blank_tracks,$i;
      next;
    }

    # if the label is the magic "dna" or "protein" flag, then add the segment using the
    # "sequence" glyph
    my $g = $conf->glyph($label);
    if (defined $g && ($g eq 'protein' || $g eq 'dna')) {
      $panel->add_track($segment,
			$conf->style($label)
			);
    }

    else {

      my $track = $panel->add_track(-glyph => 'generic',
				    -key   => $label,
				    $conf->style($label),
				   );
      $tracks{$label}  = $track;
    }

  }

  if (@feature_types) {  # don't do anything unless we have features to fetch!
    my $iterator = $segment->get_seq_stream(-type=>\@feature_types);
    my (%similarity,%feature_count);

    while (my $feature = $iterator->next_seq) {

      my $label = $self->feature2label($feature);
      my $track = $tracks{$label} or next;

      $feature_count{$label}++;

      # special case to handle paired EST reads
      if (!$lowres && $feature->method =~ /^(similarity|alignment)$/) {
	push @{$similarity{$label}},$feature;
	next;
      }
      $track->add_feature($feature);
    }

    # handle the similarities as a special case
    for my $label (keys %similarity) {
      my $set = $similarity{$label};
      my %pairs;
      for my $a (@$set) {
	(my $base = $a->name) =~ s/\.[frpq35]$//i;
	push @{$pairs{$base}},$a;
      }
      my $track = $tracks{$label};
      foreach (values %pairs) {
	$track->add_group($_);
      }
    }

    # configure the tracks based on their counts
    for my $label (keys %tracks) {
      next unless $feature_count{$label};
      $options->{$label} ||= 0;
      my $do_bump  =   $options->{$label} == 0 ? $feature_count{$label} <= $max_bump
	             : $options->{$label} == 1 ? 0
                     : $options->{$label} >= 2 ? 1
		     : 0;
      my $do_label =   $options->{$label} == 0 ? $feature_count{$label} <= $max_labels
	             : $options->{$label} == 3 ? 1
		     : 0;
      $tracks{$label}->configure(-bump  => $do_bump,
				 -label => $do_label,
				 -description => $do_label && $tracks{$label}->option('description'),
				);
      $tracks{$label}->configure(-connector  => 'none') if !$do_bump;
    }
  }

  # add additional features, if any
  my $offset = 0;
  for my $track (@blank_tracks) {
    my $file = $feature_files->{$tracks->[$track]} or next;
    ref $file or next;
    $track += $offset + 1;
    my $inserted = $file->render($panel,$track,$options->{$file});
    $offset += $inserted;
  }

  my $gd       = $panel->gd;
  return $gd   unless wantarray;

  my $boxes    = $panel->boxes;
  return ($gd,$boxes);
}

# generate the overview, if requested, and return it as a GD
sub overview {
  my $self = shift;
  my ($partial_segment) = @_;

  my $segment = $partial_segment->factory->segment($partial_segment->ref);

  my $conf  = $self->config;
  my $width = $self->width;
  my $panel = Bio::Graphics::Panel->new(-segment => $segment,
					-width   => $width,
					-bgcolor => $self->setting('overview bgcolor') || 'wheat',
				       );

  my $units = $self->setting('overview units');
  $panel->add_track($segment   => 'arrow',
		    -double    => 1,
		    -label     => sub {"Overview of ".$segment->ref},
		    -labelfont => gdMediumBoldFont,
		    -tick      => 2,
		    $units ? (-units => $units) : (),
		   );

  if (my $landmarks  = $self->setting('overview landmarks') || ($conf->label2type('overview'))[0]) {
    my $max_bump   = $conf->setting(general=>'bump density') || 50;

    my @types = split /\s+/,$landmarks;
    my $track = $panel->add_track(-glyph  => 'generic',
				  -height  => 3,
				  -fgcolor => 'black',
				  -bgcolor => 'black',
				  $conf->style('overview'),
				 );
    my $iterator = $segment->features(-type=>\@types,-iterator=>1,-rare=>1);
    my $count;
    while (my $feature = $iterator->next_seq) {
      $track->add_feature($feature);
      $count++;
    }
    $track->configure(-bump  => $count <= $max_bump,
		      -label => $count <= $max_bump
		     );
  }

  my $gd = $panel->gd;
  my $red = $gd->colorClosest(255,0,0);
  my ($x1,$x2) = $panel->map_pt($partial_segment->start,$partial_segment->end);
  my ($y1,$y2) = (0,$panel->height-1);
  $x2 = $panel->right-1 if $x2 >= $panel->right;
  $gd->rectangle($x1,$y1,$x2,$y2,$red);

  return ($gd,$segment->length);
}

# I know there must be a more elegant way to insert commas into a long number...
sub commas {
  my $i = shift;
  $i = reverse $i;
  $i =~ s/(\d{3})/$1,/g;
  chop $i if $i=~/,$/;
  $i = reverse $i;
  $i;
}

sub read_configuration {
  my $self        = shift;
  my $conf_dir    = shift;
  $self->{conf} ||= {};

  croak("$conf_dir: not a directory") unless -d $conf_dir;
  opendir(D,$conf_dir) or croak "Couldn't open $conf_dir: $!";
  my @conf_files = map { "$conf_dir/$_" } grep {/\.conf$/} readdir(D);
  close D;

  # try to work around a bug in Apache/mod_perl which appears when
  # running under linux/glibc 2.2.1
  unless (@conf_files) {
    @conf_files = glob("$conf_dir/*.conf");
  }

  # get modification times
  my %mtimes     = map { $_ => (stat($_))[9] } @conf_files;

  for my $file (sort {$b cmp $a} @conf_files) {
    my $basename = basename($file,'.conf');
    $basename =~ s/^\d+\.//;
    next if defined($self->{conf}{$basename}{mtime})
      && ($self->{conf}{$basename}{mtime} >= $mtimes{$file});
    my $config = Bio::Graphics::BrowserConfig->new(-file => $file) or next;
    $self->{conf}{$basename}{data}  = $config;
    $self->{conf}{$basename}{mtime} = $mtimes{$file};
    $self->{source} ||= $basename;
  }
  $self->{width} = DEFAULT_WIDTH;
  1;
}

sub merge {
  my $self = shift;
  my ($features,$max_range) = @_;
  $max_range ||= 100_000;

  my (%segs,@merged_segs);
  push @{$segs{$_->ref}},$_ foreach @$features;
  foreach (keys %segs) {
    push @merged_segs,_low_merge($segs{$_},$max_range);
  }
  return @merged_segs;
}

sub _low_merge {
  my ($features,$max_range) = @_;
  my $db = eval{$features->[0]->factory};

  my ($previous_start,$previous_stop,$statistical_cutoff,@spans);
  patch_biographics() unless $features->[0]->can('low');

  my @features = sort {$a->low<=>$b->low} @$features;

  # run through the segments, and find the mean and stdev gap length
  # need at least 10 features before this becomes reliable
  if (@features >= 10) {
    my ($total,$gap_length,@gaps);
    for (my $i=0; $i<@$features-1; $i++) {
      my $gap = $features[$i+1]->low - $features[$i]->high;
      $total++;
      $gap_length += $gap;
      push @gaps,$gap;
    }
    my $mean = $gap_length/$total;
    my $variance;
    $variance += ($_-$mean)**2 foreach @gaps;
    my $stdev = sqrt($variance/$total);
    $statistical_cutoff = $stdev * 2;
  } else {
    $statistical_cutoff = $max_range;
  }

  my $ref = $features[0]->ref;

  for my $f (@features) {
    my $start = $f->low;
    my $stop  = $f->high;

    if (defined($previous_stop) &&
	( $start-$previous_stop >= $max_range ||
	  $previous_stop-$previous_start >= $max_range ||
	  $start-$previous_stop >= $statistical_cutoff)) {
      push @spans,$db->segment($ref,$previous_start,$previous_stop);
      $previous_start = $start;
      $previous_stop  = $stop;
    }

    else {
      $previous_start = $start unless defined $previous_start;
      $previous_stop  = $stop;
    }

  }
  push @spans,$db ? $db->segment($ref,$previous_start,$previous_stop)
                  : Bio::Graphics::Feature->new(-start=>$previous_start,-stop=>$previous_stop,-ref=>$ref);
  return @spans;
}

# THESE SHOULD BE MIGRATED INTO BIO::GRAPHICS::FEATURE
# These fix inheritance problems in Bio::Graphics::Feature
sub patch_biographics {
  eval << 'END';
sub Bio::Graphics::Feature::low {
  my $self = shift;
  return $self->start < $self->end ? $self->start : $self->end;
}

sub Bio::Graphics::Feature::high {
  my $self = shift;
  return $self->start > $self->end ? $self->start : $self->end;
}
END
}


package Bio::Graphics::BrowserConfig;
use strict;
use Bio::Graphics::FeatureFile;
use Text::Shellwords;
use Carp 'croak';

use vars '@ISA';
@ISA = 'Bio::Graphics::FeatureFile';

sub labels {
  grep { $_ ne 'overview' } shift->configured_types;
}

sub label2type {
  my ($self,$label,$lowres) = @_;
  return ($lowres ? shellwords($self->setting($label,'feature_low')||$self->setting($label,'feature'))
                  : shellwords($self->setting($label,'feature')));
}

# override inherited in order to be case insensitive
sub type2label {
  my $self = shift;
  my $type = shift;
  $self->SUPER::type2label(lc $type);
}

sub label2index {
  my $self = shift;
  my $label = shift;
  unless ($self->{label2index}) {
    my $index = 0;
    $self->{label2index} = { map {$_=>$index++} $self->labels };
  }
  return $self->{label2index}{$label};
}

sub invert_types {
  my $self = shift;
  my $config  = $self->{config} or return;
  my %inverted;
  for my $label (keys %{$config}) {
    next if $label eq 'overview';   # special case
    for my $f (qw(feature feature_low)) {
      my $feature = $config->{$label}{$f} or next;
      foreach (shellwords($feature||'')) {
	$inverted{lc $_} = $label;
      }
    }
  }
  \%inverted;
}

sub default_labels {
  my $self = shift;
  my $defaults = $self->setting('general'=>'default features');
  return shellwords($defaults||'');
}

sub default_label_indexes {
  my $self = shift;
  my @labels = $self->default_labels;
  return map {$self->label2index($_)} @labels;
}

# return a hashref in which keys are the thresholds, and values are the list of
# labels that should be displayed
sub summary_mode {
  my $self = shift;
  my $summary = $self->settings(general=>'summary mode') or return {};
  my %pairs = $summary =~ /(\d+)\s+{([^\}]+?)}/g;
  foreach (keys %pairs) {
    my @l = shellwords($pairs{$_}||'');
    $pairs{$_} = \@l
  }
  \%pairs;
}

# override make_link to allow for code references
sub make_link {
  my $self     = shift;
  my $feature  = shift;
  my $label    = $self->feature2label($feature) or return;
  my $link     = $self->code_setting($label,'link');
  $link        = $self->code_setting(general=>'link') unless defined $link;
  return unless $link;
  return $link->($feature) if ref($link) eq 'CODE';
  return $self->link_pattern($link,$feature);
}


1;

__END__

=head1 NAME

Bio::Graphics::Browser - Support library for Generic Genome Browser

=head1 SYNOPSIS

This is a support library for the Generic Genome Browser
(http://www.gmod.org).

=head1 DESCRIPTION

Documention is pending.

=head1 SEE ALSO

L<Bio::Graphics>, L<Bio::Graphics::Panel>, the GGB installation
documentation.

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

Copyright (c) 2002 Cold Spring Harbor Laboratory

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  See DISCLAIMER.txt for
disclaimers of warranty.

=cut

THIS IS AN OLDER VERSION OF image_and_map() WHICH IS LESS PIPELINED
NOT SURE WHETHER IT IS ACTUALLY SLOWER THOUGH

# Generate the image and the box list, and return as a two-element list.
sub image_and_map {
  my $self = shift;
  my ($segment,$labels,$order) = @_;
  my %labels = map {$_=>1} @$labels;

  my $width = $self->width;
  my $conf  = $self->config;
  my $max_labels = $conf->setting(general=>'label density') || 10;
  my $max_bump   = $conf->setting(general=>'bump density')  || 50;
  my @feature_types = map {$conf->label2type($_)} @$labels;

  my $iterator = $segment->features(-type=>\@feature_types,
				    -iterator=>1);
  my ($similarity,$other) = $self->sort_features($iterator);

  my $panel = Bio::Graphics::Panel->new(-segment => $segment,
					-width   => $width,
					-keycolor => $self->setting('detailed bgcolor') || 'moccasin',
					-grid => 1,
				       );
  $panel->add_track($segment   => 'arrow',
		    -double => 1,
		    -bump =>1,
		    -tick=>2,
		   );

  # all the rest comes from configuration
  for my $label ($self->labels($order)) {  # use labels() method in order to preserve order in .conf file

    next unless $labels{$label};

    # handle similarities a bit differently
    if (my $set = $similarity->{$label}) {
      my %pairs;

      # HACK ALERT; look for feature pairs that end with [fr] and [35] suffix pairs
      # and group them.  Used for paired ESTs -- not nice.
      for my $a (@$set) {
	(my $base = $a->name) =~ s/\.[frpq35]$//i;
	push @{$pairs{$base}},$a;
      }

      my $track = $panel->add_track(-glyph =>'segments',
				    -label => @$set <= $max_labels,
				    -bump  => @$set <= $max_bump,
				    -key   => $label,
				    $conf->style($label)
				   );
      foreach (values %pairs) {
	$track->add_group($_);
      }
      next;
    }

    if (my $set = $other->{$label}) {
      $panel->add_track($set,
			-glyph => 'generic',
			-label => @$set <= $max_labels,
			-bump  => @$set <= $max_bump,
			-key   => $label,
			$conf->style($label),

		       );
      next;
    }
  }

  my $boxes    = $panel->boxes;
  my $gd       = $panel->gd;
  return ($gd,$boxes);
}

sub sort_features {
  my $self     = shift;
  my $iterator = shift;

  my (%similarity,%other);
  while (my $feature = $iterator->next_seq) {

    my $label = $self->feature2label($feature);

    # special case to handle paired EST reads
    if ($feature->method =~ /^(similarity|alignment)$/) {
      push @{$similarity{$label}},$feature;
    }

    else {  #otherwise, just sort by label
      push @{$other{$label}},$feature;
    }
  }

  return (\%similarity,\%other);
}


