package Version::Finder::MetaCPAN;
use strict;

# ABSTRACT: Find the appropriate distributions to install to satisfy version requirements using MetaCPAN

use ElasticSearch;
use Exporter qw(import);

our @EXPORT_OK = qw(find);

=head1 SYNOPSIS

    use CPAN::Meta::Requirements;
    use Version::Finder::MetaCPAN;
    
    my $reqs = CPAN::Meta::Requirements->new;
    $reqs->exact_version('Foo' => '1.00');

    my $needs = Version::Finder::MetaCPAN::find($reqs);
    
    # Returns something like
    # [
    #  {
    #   version      => 1.00,
    #   download_url => 'http://cpan.metacpan.org/authors/id/E/EX/EXAMPLE/Foo-1.00.tar.gz',
    #   distribution => 'Foo'
    #  }
    # ]

=head1 DESCRIPTION

Version::Finder::MetaCPAN uses the L<ElasticSearch|http://www.elasticsearch.org/>
index that backs L<MetaCPAN|http://www.elasticsearch.org/> to find te specific
releases of distributions that satisfy the requirements defined in a
L<CPAN::Meta::Requirements> object.

Calling C<find> creates a search with a series of filters that returns the
most recent release of a distribution that satisfies the requirements. It
understands all of the restrictions defined by L<CPAN::Meta::Requirements>.

=function find ($requirements)

Given a L<CPAN::Meta::Requirements> object, returns an arrayref of hashrefs
that point to the specific releases of each specified distribution.

=cut

sub find {
    my ($req) = @_;

    my $reqs = $req->as_string_hash;

    my $es = ElasticSearch->new(servers => 'api.metacpan.org', no_refresh => 1);

    my @results = ();
    foreach my $pack (keys %{ $reqs }) {

        my $filter = {
            and => [
                { term => { authorized => 'true' } },
                { term => { maturity => 'released' } }
            ]
        };

        my @vers = split(',', $reqs->{$pack});
        push(@{ $filter->{and} }, { term => { "release.distribution" => $pack } });
        foreach my $v (@vers) {
            if($v =~ /^==\s*(\S+)$/) {
                push(@{ $filter->{and} }, { term => { version_numified => $1 }})
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
                push(@{ $filter->{and} }, { numeric_range => { version_numified => { gte => $1 } } });
            }
        }

        my $results = $es->search(
            query       => { match_all => {} },
            fields      => [ qw(version download_url distribution) ],
            filter      => $filter,
            sort        => { version_numified => { order => 'desc' } },
            index       => 'v0',
            type        => 'release',
            size        => 1,
        );

        push(@results, $results->{hits}->{hits}->[0]->{fields});
    }
    
    return \@results;
}

1;
