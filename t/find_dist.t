use Test::More;

use Version::Finder::MetaCPAN;

my $vf = Version::Finder::MetaCPAN->new;
my $results = $vf->find_distribution_for_module('Cwd');

cmp_ok($results, 'eq', 'PathTools', 'find_distribution_for_module');

done_testing;