package Bio::Graphics::GBrowse_run;

use strict;
use Term::ANSIColor;
use Bio::Graphics::Browser::Constants;
use Bio::Graphics::Browser::Options;
use Bio::Graphics::Browser::Util;
use CGI qw(Delete_all cookie param url);
use CGI::Session;
#use CGI::ParamComposite;
use Carp qw(croak cluck);
use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use vars qw($VERSION @EXPORT_OK); #temporary
use vars qw($SESSION_DIR); # Temporary until I can figure out where I should get this value.

no warnings 'redefine';

@EXPORT_OK = qw(param); #this is a temporary scaffold to clean param() calls from gbrowse.PLS
$SESSION_DIR = '/tmp';

# LS to AD - Do we *really* need this ugliness?
sub param { print(STDERR (caller())[0]."+".(caller())[2]." called param() with: ".join(' ',map {"'$_'"} @_)."\n"); return CGI::param(@_) } #temporary

my $singleton = undef;

sub new {
  return shift->get_instance(@_);
}

sub get_instance {
  my($class,%arg) = @_;

  if(!$singleton){
    $singleton = bless {}, $class;
    $singleton->init(%arg);
  }

  return $singleton;
}

sub init {
  my($self,%arg) = @_;
  foreach my $m (keys %arg){
    $self->$m($arg{$m}) if $self->can($m);
  }

  open_database() or croak "Can't open database defined by source ".$self->config->source;

  $self->options(Bio::Graphics::Browser::Options->new());

  #read VIEW section of config file first
warn "***** read view";
  $self->read_view();
warn "***** display instructions: ".$self->options->display_instructions();
warn "***** display tracks      : ".$self->options->display_tracks();
  #then mask with session
warn "***** read session";
  $self->read_session();
warn "***** display instructions: ".$self->options->display_instructions();
warn "***** display tracks      : ".$self->options->display_tracks();
  #then mask with GET/POST parameters
warn "***** read params";
  $self->read_params();
warn "***** display instructions: ".$self->options->display_instructions();
warn "***** display tracks      : ".$self->options->display_tracks();

  #now store the masked results to the session for next time.
  #the data will be available via the ->get_session_object() accessor.
warn "***** make session";
  $self->make_session();
}

=head2 config()

 Usage   : $obj->config($newval)
 Function: 
 Example : 
 Returns : value of config (a scalar)
 Args    : on set, new value (a scalar or undef, optional)


=cut

sub config {
  my($self,$val) = @_;
  $self->{'config'} = $val if defined($val);
  return $self->{'config'};
}

=head2 config_dir()

 Usage   : $obj->config_dir($newval)
 Function: 
 Example : 
 Returns : value of config_dir (a scalar)
 Args    : on set, new value (a scalar or undef, optional)


=cut

sub config_dir {
  my($self,$val) = @_;
  $self->{'config_dir'} = $val if defined($val);
  return $self->{'config_dir'};
}


=head2 cookie()

 Usage   : $obj->cookie($newval)
 Function: 
 Example : 
 Returns : value of cookie (a scalar)
 Args    : on set, new value (a scalar or undef, optional)


=cut

sub cookie {
  my($self,$val) = @_;
  $self->{'cookie'} = $val if defined($val);
  return $self->{'cookie'};
}


=head2 options()

 Usage   : $obj->options($newval)
 Function: 
 Example : 
 Returns : A Bio::Graphics::Browser::Options object
 Args    : on set, new value (a scalar or undef, optional)


=cut

sub options {
  my($self,$val) = @_;
  $self->{'options'} = $val if defined($val);
  return $self->{'options'};
}

sub translate {
  my $self = shift;
  my $tag  = shift;
  my @args = @_;
  return $self->config->tr($tag,@args);
}

=head2 get_session_id()

 Usage   : Get/Set the session id
 Function: retrieves and stores the session id in a cookie
 Example :
 Returns : 
 Args    :


=cut

sub session_id {
    my $self           = shift;
    my $new_session_id = shift;

    if ($new_session_id) {
        $self->{'session_id'} = $new_session_id;
        $self->cookie(
            CGI::cookie(
                -name    => 'gbrowse_session_id',
                -value   => $self->{'session_id'},
                -path    => url( -absolute => 1, -path => 1 ),
                -expires => REMEMBER_SETTINGS_TIME,
            )
        );
    }

    unless ( defined( $self->{'session_id'} ) ) {
        $self->{'session_id'} = CGI::cookie("gbrowse_session_id");
    }
    return $self->{'session_id'};
}

=head2 get_session()

 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_session {
    my $self = shift;

    unless ( $self->{'session'} ) {
        my $session_id = $self->session_id();
        $self->{'session'} =
          new CGI::Session( "driver:File", $session_id,
            { Directory => $SESSION_DIR } );
        $self->session_id( $self->{'session'}->id() );    # in case it has changed
    }

    return $self->{'session'};

}

=head2 get_session_object()

 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_session_object {
    my $self = shift;

    unless ( $self->{'session_object'} ) {
        my $session = $self->get_session();
        $self->{'session_object'} = $session->param('session_object');
    }

    return $self->{'session_object'};
}

=head2 set_session_object()

 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub set_session_object {
    my $self           = shift;
    my $session_object = shift;

    $self->{'session_object'} = $session_object if ($session_object);
    my $session = $self->get_session();
    $session->param( 'session_object', $session_object );

    return $self->{'session_object'};
}

=head2 read_session()

 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub read_session {
    my ($self) = @_;

    my $session_object = $self->get_session_object();

    my $ok = 1;
    if ( $session_object and %$session_object ) {
        $ok &&= $session_object->{v} == $VERSION;
        warn "ok 0 = $ok" if DEBUG;
        last unless $ok;

        my %ok_sources = map { $_ => 1 } $self->config->sources;
        $ok &&= $ok_sources{ $session_object->{current_source} };
        $self->options->source( $session_object->{current_source} );
        my $current_source = $self->options->source;
        warn "ok 2 = $ok" if DEBUG;

        if ( $session_object->{$current_source}
            and my $current_options =
            $session_object->{$current_source}{gbrowse} )
        {

            foreach my $k ( keys %$current_options ) {
                if ( $self->options->can($k) ) {
                    $self->options->$k( $current_options->{$k} );
                }
                else {
                    warn "found option $k in session, can't handle it yet";
                }
            }

            $ok &&= defined $current_options->{width}
              && $current_options->{width} > 100
              && $current_options->{width} < 5000;
            $self->options->width( $current_options->{width} );

            warn "ok 4 = $ok" if DEBUG;
        }
    }

    #unusable session.  use default settings
    if ( !$ok ) {
        $self->options->version(100);
        $self->options->width( $self->config->setting('default width') );
        $self->options->source( $self->config->source );
        $self->options->ks('between');
        $self->options->sk('sorted');
        $self->options->id( md5_hex(rand) );    # new identity

        my @labels = $self->config->labels;
        $self->options->tracks(@labels);
        warn "order = @labels" if DEBUG;
        my %default = map { $_ => 1 } $self->config->default_labels();
        foreach my $label (@labels) {
            my $visible = $default{$label} ? 1 : 0;
            $self->options->set_feature( $label,
                { visible => $visible, options => 0, limit => 0 } )
              or warn("Unable to set the feature $_\n");
        }
    }
}

=head2 make_session()

 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub make_session {
    my ($self) = @_;

    my %settings = %{ $self->options() };

    local $^W = 0; # Why turn off warnings? BF

    #WE CAN NOW HANDLE tracks and features in the session as objects
#    for my $key ( keys %settings ) {
#        next if $key =~ /^(tracks|features)$/;    # handled specially
#        if ( ref( $settings{$key} ) eq 'ARRAY' ) {
#            $settings{$key} = join $;, @{ $settings{$key} };
#        }
#    }

    # the "features" and "track" key map to a single array
    # contained in the "tracks" key of the settings
#    my @array = map {join("/",
#            $_,
#            $settings{features}{$_}{visible},
#            $settings{features}{$_}{options},
#            $settings{features}{$_}{limit})} @{$settings{tracks}};
#    $settings{tracks} = join $;,@array;
#    delete $settings{features};
    delete $settings{flip};  # obnoxious for this to persist


    my $source = $self->config->source;
    my $session_object = $self->get_session_object();
    $session_object->{'current_source'} = $source;
    $session_object->{'v'} = $VERSION;
    $session_object->{$source}{'gbrowse'} = \%settings; 
  
    warn "session_object => ",join ' ',%$session_object,"\n" if DEBUG;

    # This used to save a cookie but now it saves a session.
    # The session id *is* stored in a cookie which is handled by session_id().
    $self->set_session_object($session_object);

}


=head2 read_params()

 Usage   :
 Function: This is called to change the values of the options
           by examining GET/POST parameters
 Example :
 Returns : 
 Args    :


=cut

sub read_params {
  my $self = shift;

  my $options = $self->options();

  if ( CGI::param('label') ) {
    my @selected = map {/^(http|ftp|das)/ ? $_ : split /[+-]/} CGI::param('label');

    #set all visibility to zero (off)
    foreach my $featuretag (keys %{ $options->features() || {} } ){
      my $feature = $options->get_feature($featuretag);
      $feature->{visible} = 0;
      $options->set_feature($featuretag,$feature);
    }

    #make selected on (visible)
    foreach my $featuretag (@selected){
      my $feature = $options->get_feature($featuretag);
      $feature->{visible} = 1;
      $options->set_feature($featuretag,$feature);
    }
  }

  #
  # action_* parameters are designed to have a universal set of parameters for file, track, and plugin
  # manipulation.  the base param name (file,track,plugin) indicates the target of the operation,
  # while the action_ param name indicates the action to be performed on the target
  #

  foreach my $k ( CGI::param() ) {
    my($section,$slot) = split /\./, $k;

    #warn "section: *$section*";
    #warn "slot   : *$slot*";

    ###FIXME not implemented yet, let's port old functionality before cleaning this up.
    #new style namespaced parameters
    #if ( defined($section) && defined($slot) ) {
    #  warn $self->options->can($section);
    #  warn $self->options->$section->can($slot);
    #  if( $self->options->can($section) && $self->options->$section->can($slot) ){
    #    warn "newstyle param set $k to ".CGI::param($k);
    #    $self->options->$section->$slot(CGI::param($k));
    #  } else {
    #    warn "found option $k in GET or POST params, can't handle it yet";
    #  }
    #}
    #old style non-namespaced parameters
    #else {
      if( $self->options->can($k) ){
        warn "oldstyle param set $k to ".CGI::param($k);
        $self->options->$k(CGI::param($k));
      } else {
        warn "found option $k ( value: '".CGI::param($k)."' )in GET or POST params, can't handle it yet";
      }
    #}
  }

  local $^W = 0;  # kill uninitialized variable warning
  if ( $options->ref() && ( $options->name() eq $options->prevname() || grep {/zoom|nav|overview/} CGI::param() ) ) {
    $options->version(CGI::param('version') || '') unless $options->version();
    $options->flip(CGI::param('flip'));
    $self->zoomnav();
    $options->name(sprintf("%s:%s..%s",$options->ref(),$options->start,$options->stop));
  }

  #strip leading/trailing whitespace
  my $name = $options->name();
  $name =~ s/^\s*(.*)\s*$/$1/;
  $options->name($name);

  if (my @external = CGI::param('eurl')) {
    my %external = map {$_=>1} @external;
    foreach (@external) {
      warn "eurl = $_" if DEBUG_EXTERNAL;
      next if $options->get_feature($_);
      $options->set_feature($_,{visible=>1,options=>0,limit=>0});
      $options->tracks($options->tracks(),$_);
    }
    # remove any URLs that aren't on the list
    foreach ( keys %{ $options->features() || {} } ) {
      next unless /^(http|ftp):/;
      $options->remove_feature($_) unless exists $external{$_};
    }
  }

   # the "q" request overrides name, ref, h_feat and h_type
  if (my @q = CGI::param('q')) {
    $options->unset($_) foreach qw(name ref h_feat h_type);
    $options->q( [map {split /[+-]/} @q] );
  }

  if (CGI::param('revert')) {
    warn "resetting defaults..." if DEBUG;
    #FIXME was this ported??? set_default_tracks($settings);
  } elsif (CGI::param('reset')) {
    $options->unset($_) foreach keys %{ $options }; #yeah, yeah, this is bad OOP.  add a slots() accessor to Options if you really care.
    Delete_all();
    #FIXME was this ported??? default_settings($settings);
  } elsif (CGI::param($self->translate('adjust_order')) && !CGI::param($self->translate('cancel'))) {
    #FIXME adjust_track_options($settings);
    #FIXME adjust_track_order($settings);
  }
}

sub read_view {
  my($self) = shift;

  ###FIXME there is certainly a better way to get this data, but i'm in a hurry right now.
  if( $self->config()->{conf}{$self->config()->source()}{data}{config}{VIEW} ){
    my %o = %{ $self->config()->{conf}{$self->config()->source()}{data}{config}{VIEW} };
    #foreach potential view parameter
    foreach my $k (keys %o){
      if( $self->options->can($k) ) {
#        warn "setting view option $k to $o{$k}";
        $self->options->$k($o{$k});
      } else {
        warn "found option $k in config file VIEW section, can't handle it yet";
      }
    }
  }
}

=head2 template()

 Usage   : $obj->template($newval)
 Function: holds a Template Toolkit instance
 Example : 
 Returns : value of template (a scalar)
 Args    : on set, new value (a scalar or undef, optional)

=cut

sub template {
  my($self) = @_;
  if ( ! $self->{'template'} ) {
    # User can change template include directory within the config file
    my $template_dir    = $self->config->setting(general => 'templates') || 'default';
    #FIXME this should really be File::Spec::Functions / catfile()
    $template_dir       = $self->config_dir()."/templates/$template_dir" unless $template_dir =~ m!^/!;
    $self->{'template'} = Template->new({
                                         INCLUDE_PATH => $template_dir,
                                         ABSOLUTE     => 1,
                                         EVAL_PERL    => 1,
                                        }) || die("couldn't create template: $!");

  }
  return $self->{'template'};
}

=head2 zoomnav()

 Usage   :
 Function: computes the new values for start and stop when the user made use
           of slider.tt2 and navigationtable.tt2
 Example :
 Returns :
 Args    :

=cut

sub zoomnav {
  my $self = shift;
  my $options = $self->options();
  return undef unless $options->ref();

  my $start          = $options->start();
  my $stop           = $options->stop();
  my $span           = $stop - $start + 1;
  my $flip           = $options->flip() ? -1 : 1;
  my $segment_length = $options->seg_length();

  warn "before adjusting, start = $start, stop = $stop, span=$span" if DEBUG;

  # get zoom parameters

  #clicked zoom +/- button
  if ( $options->zoom() && CGI::param('zoom.x') ) {
    my $zoom = $options->zoom();
    my $zoomlevel = $self->zoomnavfactor( $options->zoom() );
    warn "zoom = $zoom, zoomlevel = $zoomlevel" if DEBUG;
    my $center	    = int($span / 2) + $start;
    my $range	    = int($span * (1 - $zoomlevel)/2);
    $range          = 2 if $range < 2;
    ($start, $stop) = ($center - $range , $center + $range - 1);
  }

  #clicked overview image
  elsif ( defined($segment_length) && CGI::param('overview.x') ) {
###FIXME not ported yet b/c of overview tracks options datastructure
#    my @overview_tracks = grep {$options->{features}{$_}{visible}} 
#         $self->config->overview_tracks;
#    my ($padl,$padr) = $self->config->overview_pad(\@overview_tracks);
#
#    my $overview_width = ($options->width() * OVERVIEW_RATIO);
#
#    # adjust for padding in pre 1.6 versions of bioperl
#    $overview_width -= ($padl+$padr) unless Bio::Graphics::Panel->can('auto_pad');
#    my $click_position = $segment_length * ( CGI::param('overview.x') - $padl ) / $overview_width;
#
#    $span = $self->config->get_default_segment() if $span > $self->config->get_max_segment();
#    $start = int( $click_position - ($span / 2) );
#    $stop  = $start + $span - 1;
  }

  #scrolled left
  elsif ( $options->navleft() && CGI::param('navleft.x') ) {
    my $navlevel = $self->zoomnavfactor( $options->navleft() );
    $start += $flip * $navlevel;
    $stop  += $flip * $navlevel;
  }

  #scrolled right
  elsif ( $options->navright() && CGI::param('navright.x') ) {
    my $navlevel = $self->zoomnavfactor( $options->navright() );
    $start += $flip * $navlevel;
    $stop  += $flip * $navlevel;
  }

  #selection from dropdown menu
  elsif ( $options->span() ) {
    warn "selected_span = ".$options->span() if DEBUG;
    my $center	    = int(($span / 2)) + $start;
    my $range	    = int(($options->span())/2);
    $start          = $center - $range;
    $stop           = $center + $range - 1;
  }



#  warn "after adjusting for navlevel, start = $start, stop = $stop, span=$span" if DEBUG;
#
#  # to prevent from going off left end
#  if ($start < 1) {
#    warn "adjusting left because $start < 1" if DEBUG;
#    ($start,$stop) = (1,$stop-$start+1);
#  }
#
#  # to prevent from going off right end
#  if (defined $segment_length && $stop > $segment_length) {
#    warn "adjusting right because $stop > $segment_length" if DEBUG;
#    ($start,$stop) = ($segment_length-($stop-$start),$segment_length);
#  }
#
#  # to prevent divide-by-zero errors when zoomed down to a region < 2 bp
#  $stop  = $start + ($span > 4 ? $span - 1 : 4) if $stop <= $start+2;
#
#  warn "start = $start, stop = $stop\n" if DEBUG;
#
#  my $divisor = $self->config->setting(general=>'unit_divider') || 1;
  my $divisor = 1;
  $options->start($start/$divisor);
  $options->stop($stop/$divisor);
}

=head2 zoomnavfactor()

 Usage   :
 Function: convert Mb/Kb back into bp... or a ratio, used by L</zoomnav()>
 Example :
 Returns : 
 Args    :

=cut

sub zoomnavfactor {
  my $self = shift;
  my $string = shift;

  my ($value,$units) = $string =~ /(-?[\d.]+) ?(\S+)/;

  return unless defined $value;

  $value /= 100   if $units eq '%';  # percentage;
  $value *= 1000  if $units =~ /kb/i;
  $value *= 1e6   if $units =~ /mb/i;
  $value *= 1e9   if $units =~ /gb/i;

  return $value;
}


################################################################
## TODO port these functions
################################################################

#NOT YET PORTED OUT OF gbrowse.PLS
# # reorder @labels based on settings in the 'track.XXX' parameters
# sub adjust_track_order {
#   my $settings = shift;

#   my @labels  = $BROWSER->options->tracks();
#   warn "adjust_track_order(): labels = @labels" if DEBUG;

#   my %seen_it_already;
#   foreach (grep {/^track\./} CGI::param()) {
#     warn "$_ =>",CGI::param($_) if DEBUG;
#     next unless /^track\.(\d+)/;
#     my $track = $1;
#     my $label   = CGI::param($_);
#     next unless length $label > 0;
#     next if $seen_it_already{$label}++;
#     warn "$label => track $track" if DEBUG;

#     # figure out where features currently are
#     my $i = 0;
#     my %order = map {$_=>$i++} @labels;

#     # remove feature from wherever it is now
#     my $current_position = $order{$label};
#     warn "current position of $label = $current_position" if DEBUG;
#     splice(@labels,$current_position,1);

#     warn "new position of $label = $track" if DEBUG;
#     # insert feature into desired position
#     splice(@labels,$track,0,$label);
#   }
#   $BROWSER->options->tracks(@labels);
# }

# sub adjust_track_options {
#   my $settings = shift;
#   foreach (grep {/^option\./} CGI::param()) {
#     my ($track)   = /(\d+)/;
#     my $feature   = $BROWSER->options->{tracks}[$track];
#     my $option    = CGI::param($_);
#     $BROWSER->options->{features}{$feature}{options} = $option;
#   }
#   foreach (grep {/^limit\./} CGI::param()) {
#     my ($track)   = /(\d+)/;
#     my $feature   = $BROWSER->options->{tracks}[$track];
#     my $option    = CGI::param($_);
#     $BROWSER->options->{features}{$feature}{limit} = $option;
#   }
#   foreach (@{$BROWSER->options->{tracks}}) {
#     $BROWSER->options->{features}{$_}{visible} = 0;
#   }

#   foreach (CGI::param('track.label')) {
#     $BROWSER->options->{features}{$_}{visible} = 1;
#   }
# }




1;