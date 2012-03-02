package Version::Finder::MetaCPAN;
use strict;

# ABSTRACT: Find the appropriate distributions to install to satisfy version requirements using MetaCPAN

use ElasticSearch;
use Exporter qw(import);
use MetaCPAN::API;
use Moose;
use Try::Tiny;
use version;

=head1 SYNOPSIS

    use CPAN::Meta::Requirements;
    use Version::Finder::MetaCPAN;
    
    my $reqs = CPAN::Meta::Requirements->new;
    $reqs->exact_version('Foo' => '1.00');

    my $vf = Version::Finder::MetaCPAN->new;
    my $needs = $vf->find($reqs);
    
    # Returns something like
    # [
    #  {
    #   version      => 1.00,
    #   download_url => 'http://cpan.metacpan.org/authors/id/E/EX/EXAMPLE/Foo-1.00.tar.gz',
    #   distribution => 'Foo'
    #   # and a bunch of other stuff
    #  }
    # ]

=head1 DESCRIPTION

Version::Finder::MetaCPAN uses the L<ElasticSearch|http://www.elasticsearch.org/>
index that backs L<MetaCPAN|http://www.elasticsearch.org/> to find the specific
releases of distributions that satisfy the requirements defined in a
L<CPAN::Meta::Requirements> object.

Calling C<find> creates a search with a series of filters that returns the
most recent release of a distribution that satisfies the requirements. It
understands all of the restrictions defined by L<CPAN::Meta::Requirements>.

=cut

has '_es' => (
    is => 'ro',
    isa => 'ElasticSearch',
    lazy => 1,
    default => sub {
        ElasticSearch->new(servers => 'api.metacpan.org', no_refresh => 1)
    }
);

has '_mca' => (
    is => 'ro',
    isa => 'MetaCPAN::API',
    lazy => 1,
    default => sub {
        MetaCPAN::API->new
    }
);

has '_distcache' => (
    traits => [ 'Hash' ],
    is => 'ro',
    isa => 'HashRef',
    default => sub { { } },
    handles => {
        add_to_dist_cache   => 'set',
        get_from_dist_cache => 'get',
        in_dist_cache       => 'exists'
    }
);

has '_seencache' => (
    traits => [ 'Hash' ],
    is => 'ro',
    isa => 'HashRef',
    default => sub { { } },
    handles => {
        add_to_seen_cache   => 'set',
        get_from_seen_cache => 'get',
        in_seen_cache       => 'exists'
    }
);

=method find ($requirements)

Given a L<CPAN::Meta::Requirements> object, returns an arrayref of hashrefs
that point to the specific releases of each specified distribution.

=cut

sub find {
    my ($self, $req) = @_;

    my $reqs = $req->as_string_hash;

    my @results = ();
    foreach my $pack (keys %{ $reqs }) {

        my $filter = {
            and => [
                # XX Document this
                { term => { authorized => 'true' } },
                { term => { maturity => 'released' } }
            ]
        };

        my $dist = $self->find_distribution_for_module($pack);
        if(!$dist) {
            print "Giving up on $pack\n";
            next;
        }

        $dist =~ s/::/-/g;
        push(@{ $filter->{and} }, { term => { 'release.distribution' => $dist } });
        my @vers = split(',', $reqs->{$pack});
        # XX There is definitely a problem with numified versions and _ and such here
        foreach my $v (@vers) {
            if($v =~ /v/) {
                #damnit. numify it?
                $v = version->parse($v)->numify
            }
            if($v =~ /^==\s*(\S+)$/) {
                push(@{ $filter->{and} }, { term => { version_numified => $1 }});
            } elsif($v =~ /^>=\s*(\S+)/) {
                push(@{ $filter->{and} }, { numeric_range => { version_numified => { gte => $1 } } });
            } elsif($v =~ /^>\s*(\S+)/) {
                push(@{ $filter->{and} }, { numeric_range => { version_numified => { gt => $1 } } });
            } elsif($v =~ /^<=\s*(\S+)/) {
                push(@{ $filter->{and} }, { numeric_range => { version_numified => { lte => $1 } } });
            } elsif($v =~ /^<\s*(\S+)/) {
                push(@{ $filter->{and} }, { numeric_range => { version_numified => { lt => $1 } } });
            } elsif($v =~ /^!=\s+(\S+)/) {
                push(@{ $filter->{and} }, { not => { term => { version_numified => $1 } } });
            } else {
                push(@{ $filter->{and} }, { numeric_range => { version_numified => { gte => $v } } });
            }
        }

        my $results = $self->_es->search(
            query       => { match_all => {} },
            fields      => '*', #[ qw(version download_url distribution) ],
            filter      => $filter,
            sort        => { version_numified => { order => 'desc' } },
            index       => 'v0',
            type        => 'release',
            # size        => 1,
        );
        
        if(!keys(%{ $results->{hits}->{hits}->[0]->{fields} })) {
            print STDERR "Cannot find valid file for $dist ".$reqs->{$pack}."\n";
        }
        
        push(@results, $results->{hits}->{hits}->[0]->{fields});
    }
    
    return \@results;
}

=method find_distribution_for_module ('Some::Module')

Find the name of the distribution that provides the module with the specified
name.

=cut

sub find_distribution_for_module {
    my ($self, $module) = @_;
    
    if($module =~ /-/) {
        # I was seeing modules come in with a - instead of :: form time to time.
        # Weird.
        $module =~ s/-/::/g;
    }
    if($self->in_dist_cache($module)) {
        # print "## Cache hit\n";
        return $self->get_from_dist_cache($module);
    }
    my $dist = undef;
    try {
        # print "!! $module\n";
        my $result = $self->_mca->fetch('/module/'.$module);
        if(defined($result)) {
            $dist = $result->{distribution};
        }
        $self->add_to_dist_cache($module, $dist);
    } catch {
        print STDERR "Failed to find $module, try other things?\n";
    };
    
    return $dist;
}

=method build_deps ($reqs)

Given a L<CPAN::Meta::Requirements> object this method inspects the
dependencies recursively and returns a new L<CPAN::Meta::Requirements> object
that contains the combined requirements of the original object and all
dependents.

=cut

sub build_deps {
    my ($self, $req) = @_;
    
    my $finalreqs = $req->clone;
    
    # Get the information from metacpan
    my $modules = $self->find($finalreqs);
    
    # Check each module…
    foreach my $mod (@{ $modules }) {

        # dependencies
        my $depmods  = $mod->{'dependency.module'};
        my $depvers  = $mod->{'dependency.version'};
        my $deprels  = $mod->{'dependency.relationship'};
        my $depphase = $mod->{'dependency.phase'};
        
        # No deps, skip this one
        next unless defined($depmods);
                
        # Stupid thing returns a scalar rather than an arrayref if there is
        # only one, so normalize things.
        if(ref($depmods) ne 'ARRAY') {
            $depmods = [ $depmods ];
        }
        if(ref($depvers) ne 'ARRAY') {
            $depvers = [ $depvers ];
        }
        if(ref($deprels) ne 'ARRAY') {
            $deprels = [ $deprels ];
        }
        if(ref($depphase) ne 'ARRAY') {
            $depphase = [ $depphase ];
        }

        # Look at each dep…
        for(my $i = 0; $i < scalar(@{ $depmods }); $i++) {

            # Only do requires and runtime deps
            next if $deprels->[$i] ne 'requires';
            next if $depphase->[$i] ne 'runtime';

            my $module = $depmods->[$i];
            
            my $dist = $self->find_distribution_for_module($module);

            if(!$dist) {
                print "Counldn't find dist for $module, giving up. Install it your damn self.\n";
                next;
            }
            # We already got perl
            next if $dist eq 'perl';

            my $ver = $depvers->[$i];

            # Add this dep as a requirement
            my $new_reqs = CPAN::Meta::Requirements->new;
            $new_reqs->add_string_requirement($dist, $ver);
            
            # Check if we've already chased this dep by:
            #  Checking the cache
            #  Checking that the version we're being asked to see is >= what we already have
            #  Verifying that the requirements don't hate the module+version
            unless($self->in_seen_cache($dist) && (version->parse($ver)->numify >= $self->get_from_seen_cache($dist)) && $finalreqs->accepts_module($dist => $ver)) {
                # Make an entry in the cache
                $self->add_to_seen_cache($dist, version->parse($ver)->numify);
                # Recurse! Find the deps of this one!
                my $deeper = $self->build_deps($new_reqs);
                if(defined($deeper) && scalar($deeper->required_modules)) {
                    # Add our sub-calls reqs to ours
                    $finalreqs->add_requirements($deeper);
                }
            }
        }
    }
    return $finalreqs;
}

1;
