# $Id: Importer.pm,v 1.18 2005/12/02 05:28:38 asc Exp $
# -*-cperl-*-

package MT::Import::Mbox::Importer;
use strict;

$MT::Import::Mbox::Importer::VERSION = '1.0';

=head1 NAME

MT::Import::Mbox::Importer - wrapper class for importing a collection of mbox folders using MT::Import::Mbox.

=head1 SYNOPSIS

 use MT::Import::Config::Importer;

 my $mt = MT::Import::Mbox::Importer->new("/path/to/config");
 $mt->collect();

 # You can also do this :

 my $cfg = Config::Simple->new(...);
 my $mt = MT::Import::Mbox::Importer->new($cfg);
 $mt->collect();

=head1 DESCRIPTION

This is a wrapper class for importing a collection of mbox folders into
Movable Type using MT::Import::Mbox.

=cut

use Config::Simple;

use File::Find::Rule;
use File::Spec;

use MT::Import::Mbox;

use Date::Parse;
use Memoize;

use Log::Dispatch;
use Log::Dispatch::Screen;

&memoize("compare_period","_mk_cmp","_today");

=head1 IMPORTANT

You should really familiarize yourself with MT::Import::Mbox before going
any further.

=head1 REALLY IMPORTANT

This package relies on a very particular archiving pattern for email messages :
Individual messages stored in a series of nested folders labeled by year (YYYY), 
month (MM) and day (DD).

B<This is not a feature.>

It just happens to be the way that I<I> store my email. If you want to buy me
a beer sometime we can talk about why. The short version is that I wrote this
package as a personal helper module for using I<MT::Import::Mbox>.

Aside from bug fixes the top of the TO DO list for this package is to provide
a way for users to define a custom "match" criteria to identify mbox files. I
am hoping to do this using Regexp::English so that custom patterns can be added
to the config file. Forcing users to write their own callback functions is not
an ideal solution.

One problem with allowing custom matches is how this would work with date
filtering, via the B<period> option (see below). Checking the last modified
time on inidividual mboxes is a possibility but error-prone, to say the least.

Suggestions and patches are welcome.

=head1 OPTIONS

Options are passed to MT::Import::Mbox::Importer using a Config::Simple object
or a valid Config::Simple config file. Options are grouped by "block".

=head2 importer

=over 4

=item * B<period>

String.

This specifies a time-based limiting criteria for importing mboxes. The syntax is
B<(n)(modifier)> where B<(n)> is a positive integer and B<(modifier)>
may be one of the following :

=over 4

=item * B<h>

Import mboxes that are younger than B<(n)> hours.

=item * B<d>

Import mboxes that are younger than B<(n)> days.

=item * B<w>

Import mboxes that are younger than B<(n)> weeks.

=item * B<M>

Import mboxes that are younger than B<(n)> months.

=back

=item * B<verbose>

Boolean.

Enable verbose logging for both this package and I<MT::Import::Mbox>

=item * B<force>

Boolean.

Force a message to be reindexed, including any trackback pings and
attachments. If an entry matching the message id already exists in the
database it should only ever update or overwrite I<existing> data.

Default is I<false>

=back

=head2 mbox

=over 4

=item * B<type>

String. I<required>

Used to build a regular expression for identifying mbox paths to import.
Supported types are :

=over 4

=item * B<thunderbird>

=item * B<entourage>

Entourage support is still a bit funky because I am having trouble getting
the mbox parser to DWIM with carriage returns. Buyer beware, patches welcome,
etc.

=back

=item * B<root>

The path to your mail archive.

String. I<required>

=back

=head2 mt 

=over 4

=item * B<root>

String. I<required>

The path to your Movable Type installation.

=item * B<blog_id>

Int. I<required>

The numberic ID of the Movable Type weblog you are posting to.

=item * B<blog_ownerid>

Int. I<required>

The numberic ID of a Movable Type author with permissions to add
new authors to the Movable Type weblog you are posting to.

=item * B<author_pass>

String.

The password to assign to any new authors you add to the Movable Type
weblog you are posting to.

Default is "I<none>".

=item * B<author_perms>

Int.

The permissions set to grant any new authors you add to the Movable Type
weblog you are posting to.

Default is I<514>, or the ability to add new categories.

=back

=head2 email

=over 4

=item * B<personal>

String.

A comma separated list of email addresses that are recognized to be "personal".
When they are present in a message's I<From> header the message will be categorized
as 'Sent' rather than 'Received'.

=back

=cut

sub new {
        my $pkg  = shift;
        my $opts = shift;

        my $self = bless {}, $pkg;
        
        if (! $self->init($opts)) {
                undef $self;
                return undef;
        }
        
        return $self;
}

sub init {
        my $self = shift;
        my $opts = shift;
        
        if (UNIVERSAL::isa($opts,"Config::Simple")) {
                $self->{cfg} = $opts;
        }

        else {
                my $cfg  = undef;
        
                eval {
                        $cfg = Config::Simple->new($opts);
                };
                
                if ($@) {
                        warn $@;
                        return 0;
                }
                
                $self->{cfg} = $cfg;
        }

        #
        
        my $log_fmt = sub {
                my %args = @_;
                
                my $msg = $args{'message'};
                chomp $msg;
                
                my ($ln,$sub) = (caller(4))[2,3];
                $sub =~ s/.*:://;
                
                return sprintf("[%s][%s, ln%d] %s\n",
                               $args{'level'},$sub,$ln,$msg);
        };
        
        my $logger = Log::Dispatch->new(callbacks=>$log_fmt);

        if (! $logger) {
                warn "failed to create logger, $!";
                return undef;
        }

        my $error  = Log::Dispatch::Screen->new(name      => '__error',
                                                min_level => 'error',
                                                stderr    => 1);
        
        $logger->add($error);
        $self->{'__logger'} = $logger;
        
        #
        
        $self->verbose($self->{cfg}->param("importer.verbose"));
        return 1;
}

=head1 OBJECT METHODS

=cut

=head2 $obj->collect()

Returns true or false.

=cut

sub collect {
        my $self = shift;

        my $match = $self->mk_match($self->{cfg}->param("mbox.type"));
        
        if (! $match) {
                $self->log()->error("failed to build match - exiting");
                return 0;
        }
        
        #
        
        my $mt = MT::Import::Mbox->new($self->{cfg});
        
        if (! $mt) {
                $self->log()->error("failed to create MT::Import::Mbox object, exiting");
                return 0;
        }
        
        $mt->verbose($self->{cfg}->param("importer.verbose"));
        
        #
        
        my $rule = File::Find::Rule->new();
        $rule->file();
        
        $rule->exec(sub {
                            my $short = shift;
                            my $long  = shift;
                            my $full  = shift;
                            
                            my $match = &$match($full,$self->{cfg}->param("importer.period"));
                            $self->log()->info("is $full a match : $match");
                            return $match;
                    });
        
        #
        
        my $root = $self->{cfg}->param("mbox.root");
        
        if (! -d $root) {
                $self->log()->error("mbox root is not a directory, exiting");
                return 0;
        }
        
        #
        
        foreach my $path ($rule->in($root)) {
                $self->log()->info("import $path");
                $mt->import_mbox($path);
        }
        
        #
        
        $mt->rebuild();
        return 1;
}

sub mk_match {
        my $pkg  = shift;
        my $type = shift;
        
        if ($type eq "thunderbird") {
                return \&mk_match_thunderbird;
        }
        
        elsif ($type eq "entourage") {
                return \&mk_match_entourage;
        }
        
        else {
                warn "unknown or unsupported mbox, '$type'";
                return undef;
        }
}

sub mk_match_thunderbird {
        my $path    = shift;
        my $period  = shift;

        my $root = File::Spec->catdir("","(\\d{4})\\.sbd","(\\d{2})\\.sbd");
        my $file = File::Spec->catfile($root,"(\\d{2})");
        
        my $pattern = qr!$file$!;
        
        return &_mk_match($path,$period,$pattern);
}

sub mk_match_entourage {
        my $path    = shift;
        my $period  = shift;

        my $root = File::Spec->catdir("","(\\d{4})","(\\d{2})","(\\d{2})");
        my $file = File::Spec->catfile($root,"(\\d{2})\\.mbox");
        
        my $pattern = qr!$file$!;

        return &_mk_match($path,$period,$pattern);
}

sub mk_match_evolution {
        my $path   = shift;
        my $period = shift;

        # FIX ME
        my $pattern = qr/\/(\d{4})\/(\d{2})\/(\d{2})\/(\d{2}).mbox$/;

        return &_mk_match($path,$period,$pattern);
}

=head2 $obj->verbose($bool)

Returns true or false, indicating whether or not I<debug> events
would be logged.

=cut

sub verbose {
        my $self = shift;
        my $bool = shift;
        
        #
        
        if (defined($bool)) {
                
                $self->log()->remove('__verbose');
                
                if ($bool) {
                        my $stdout = Log::Dispatch::Screen->new(name      => '__verbose',
                                                                min_level => 'debug');
                        $self->log()->add($stdout);
                }
        }
        
        #
        
        return $self->log()->would_log('debug');
}

=head2 $obj->log()

Returns a I<Log::Dispatch> object.

=cut

sub log {
        my $self = shift;
        return $self->{'__logger'};
}

sub _mk_match {
        my $path    = shift;
        my $period  = shift;
        my $pattern = shift;
        
        if ($path !~ /$pattern/) {
                return 0;
        }
        
        elsif (! $period) {
                return 1;
        }
        
        else {
                my $yyyy = $1;
                my $mm   = $2;
                my $dd   = $3;
                
                return &compare_period("$yyyy-$mm-$dd",$period);
        }
        
}

sub compare_period {
        my $ymd = shift;
        my $cmp = shift;
        
        return (str2time($ymd) >= (&_today() - &_mk_cmp($cmp))) ? 1 : 0;
}

sub _today {
        my ($d,$m,$y) = (localtime())[3,4,5];
        my $ymd = sprintf("%04d-%02d-%02d",$y+1900,$m+1,$d);
        return str2time($ymd);
}

sub _mk_cmp {
        my $cmp = shift;
        
        $cmp =~ /^(\d+)([hdwM])$/;
        
        my $count  = $1;
        my $period = $2;
        
        # print "count $count : period $period\n";
        
        if ((! $count) || (! $period)) {
                return -1;
        }
        
        #
        
        if ($period eq "h") {
                return $count * (60 * 60);
        }
        
        elsif ($period eq "d") {
                return $count * (24 * (60 * 60));
        }
        
        elsif ($period eq "w") {
                return $count * (7 * (24 * (60 * 60)));
        }
        
        elsif ($period eq "M") {
                return $count * (4 * (7 * (24 * (60 * 60))));
        }
        
        else {
                return -1;
        }
}

=head1 VERSION

1.0

=head1 DATE

$Date: 2005/12/02 05:28:38 $

=head1 AUTHOR

Aaron Straup Cope E<lt>ascope@cpan.orgE<gt>

=head1 SEE ALSO 

L<MT::Import::Mbox>

=head1 BUGS

Entirely possible. This package has not been tested on a Windows
box. Please report all bugs via :

L<http://rt.cpan.org>

=head1 LICENSE

Copyright (c) 2005 Aaron Straup Cope. All rights reserved.

This is free software, you may use it and distribute it under
the same terms as Perl itself.

=cut

return 1;

__END__
