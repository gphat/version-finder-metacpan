use Version::Finder::MetaCPAN;
use CPAN::Meta::Requirements;
use Data::Dumper;

my $req = CPAN::Meta::Requirements->new;
$req->add_string_requirement('Moose', '== 2.0401');

my $vf = Version::Finder::MetaCPAN->new;
my $results = $vf->build_tree_deps('Chart::Clicker', '2.0', $req);

# print Dumper($results);

my @items;
$results->traverse(sub {
    my ($_tree) = @_;
    my $info = $_tree->getNodeValue->info;
    push(@items, { depth => $_tree->getDepth, info => $info });
    # print (("\t" x $_tree->getDepth), $info->{distribution}, " (", $info->{download_url}, ")\n");
});

my @sorted = reverse sort { $a->{depth} <=> $b->{depth} } @items;

foreach my $item (@sorted) {
    print $item->{info}->{download_url}."\n";
}

# $vf->install_it($results);