package Version::Finder::MetaCPAN;
use strict;

# ABSTRACT: Find the appropriate distributions to install to satisfy version requirements using MetaCPAN

use ElasticSearch;
use Exporter qw(import);
use MetaCPAN::API;
use Moose;
use Tree::Simple;
use Try::Tiny;
use version;

=head1 SYNOPSIS

    use Version::Finder::MetaCPAN;
    use CPAN::Meta::Requirements;

    my $req = CPAN::Meta::Requirements->new;
    $req->add_string_requirement('Moose', '== 2.0401');

    my $vf = Version::Finder::MetaCPAN->new;
    # Find all the requirements for the Requirements we've defined.
    # The Chart::Clicker and 2.0 parts are just for information, the $req
    # object is all that matters.
    my $results = $vf->build_tree_deps('Chart::Clicker', '2.0', $req);

    # Flatten and get the depth
    my @items;
    $results->traverse(sub {
        my ($_tree) = @_;
        my $info = $_tree->getNodeValue->info;
        push(@items, { depth => $_tree->getDepth, info => $info });
    });

    # Sort to find the deepest deps.
    my @sorted = reverse sort { $a->{depth} <=> $b->{depth} } @items;

    # Print out the tarballs we need
    foreach my $item (@sorted) {
        print $item->{info}->{download_url}."\n";
    }

=head1 DESCRIPTION

B<Warning: Version::Finder::MetaCPAN is experimental. It might be broken, return
incorrect results or change drastically. Help is welcome!>

Version::Finder::MetaCPAN uses the L<ElasticSearch|http://www.elasticsearch.org/>
index that backs L<MetaCPAN|http://www.elasticsearch.org/> to find the specific
releases of distributions that satisfy the requirements defined in a
L<CPAN::Meta::Requirements> object.

Calling C<find> creates a search with a series of filters that returns the
most recent release of a distribution that satisfies the requirements. It
understands all of the restrictions defined by L<CPAN::Meta::Requirements>.

=head1 OVERVIEW

Version::Finder::MetaCPAN is able to answer this question: Given a couple
of modules and their requirements, what do I need to fetch from CPAN to get
it all working?

    my $reqs = CPAN::Meta::Requirements->new;
    $reqs->add_minimum('Moose' => '2.0');
    $reqs->add_maximum('Graphics::Primitive' => '0.60'); # Maybe 1.0 is incompatible
    $reqs->exact_version('Try::Tiny' => '0.11'); # I insist!
    
    my $vf = Version::Finder::MetaCPAN->new;
    my $results = $vf->find($results);

    foreach my $dep (@{ $results }) {
        print $dep->{download_url}."\n";
    }

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
            print STDERR "Giving up on $pack\n";
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

=method build_tree_deps ($dist, $ver, $reqs)

Given a dist name, version and L<CPAN::Meta::Requirements> object this method inspects the
dependencies recursively and returns a L<Tree::Simple> object representing the
recursively resolved dependencies of all modules.

=cut

sub build_tree_deps {
    my ($self, $dist, $ver, $reqs) = @_;

    my $vfreqs = Version::Finder::MetaCPAN::Requirements->new(
        dist => $dist,
        version => $ver,
        reqs => $reqs,
    );

    my $root = Tree::Simple->new($vfreqs, Tree::Simple->ROOT);
    
    $self->add_tree_deps($reqs, $root);
    
    return $root;
}

sub add_tree_deps {
    my ($self, $req, $parent) = @_;
    
    # Get the information from metacpan
    my $modules = $self->find($req);
    
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

        my $newreqs = CPAN::Meta::Requirements->new;
        # Make the leaf node for this dep and fill it with 
        my $leaf = Tree::Simple->new(Version::Finder::MetaCPAN::Requirements->new(
            info => $mod,
            reqs => $newreqs
        ), $parent);

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

            # Check if we've already chased this dep by:
            #  Checking the cache
            #  Checking that the version we're being asked to see is >= what we already have
            unless($self->in_seen_cache($dist) && (version->parse($ver)->numify >= $self->get_from_seen_cache($dist))) {
                # Make an entry in the cache
                $self->add_to_seen_cache($dist, version->parse($ver)->numify);

                $newreqs->add_string_requirement($dist, $ver);
            }
        }
        # Recurse! Find the deps of this one!
        $self->add_tree_deps($newreqs, $leaf);
    }
}


package Version::Finder::MetaCPAN::Requirements;
use Moose;

has 'info' => (
    is => 'ro',
    isa => 'HashRef'
);

has 'reqs' => (
    is => 'ro',
    isa => 'CPAN::Meta::Requirements'
);

1;
