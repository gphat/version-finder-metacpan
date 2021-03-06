use Test::More;

use Version::Finder::MetaCPAN;
use CPAN::Meta::Requirements;

my $req = CPAN::Meta::Requirements->new;
$req->exact_version(Moose => '1.0');

my $vf = Version::Finder::MetaCPAN->new;
my $results = $vf->find($req);

cmp_ok($results->[0]->{version}, 'eq', '1.00', 'Check version');

done_testing;