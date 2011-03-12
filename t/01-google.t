##!perl -w
# Scraping from Google search, just for testing.
# Inspired by this Java HtmlUnit tutorial:
# http://java.dzone.com/articles/htmlunit-%E2%80%93-quick-introduction

use strict;
use warnings;

use Test::More;

BEGIN {
    use lib '../lib';
    use_ok( 'WWW::HtmlUnit::Spidey' ) || print "Bail out!
";
}

# Common prefix for HtmlUnit classes as seen from Perl.
my $x = 'WWW::HtmlUnit::com::gargoylesoftware::htmlunit::';

# webClient represents a web browser, emulating IE 8.
my $webClient = browser 'ini', emu => 'INTERNET_EXPLORER_8';
isa_ok( $webClient, "${x}WebClient" );

# If a site does not use JavaScript or JavaScript support is not
# essential for scraping just disable it and gain performance.
#browser 'js', 'off';

# Get the home page, class HtmlPage, a single HTML page.
my $homePage;
eval {
    $homePage = browser 'go', $webClient, 'http://google.com/';
    isa_ok( $homePage, "${x}html::HtmlPage" );

    1;
};

SKIP: {
    skip "No network connection seems to be available", 1 if $@;

    is( $homePage->getTitleText( ), 'Google', 'Page title match' );

    #my $text = $homePage->asText( );
    #my $xmlSource = $homePage->asXml( );

    # Default get method is by Id.
    my $logo = node(page => $homePage, match => 'hplogo');
    # Class will be HtmlDivision because the Google logo is really a div with a
    # background.
    isa_ok( $logo, "${x}html::HtmlDivision" );

    # Get the logo URL, sth like /intl/en_com/images/srpr/logo1w.png
    $logo->getAttribute( 'style' ) =~ /background:url\((.*?)\)/;
    is( $1, '/intl/en_com/images/srpr/logo1w.png', 'Logo url extracted' );

    # Select the <a href="/advanced_search?hl=en">Advanced Search</a> link.
    # Also available to select a link are getAnchorByName( ), getAnchorByHref( ).
    # Note that getAnchorByText is case sensitive.
    my $advSearchAn = $homePage->getAnchorByText( 'Advanced search' );
    isa_ok( $advSearchAn, "${x}html::HtmlAnchor" );

    # Browse to the advanced search page.
    my $curPage = $advSearchAn->click( );
    is( $curPage->getTitleText( ), 'Google Advanced Search', 'Page title match' );

    # Make a search!

    # Set the query input text.
    node(action => 'set', page => $homePage, by => 'name', match => 'q',
        value => 'arch linux');

    # Submit the form by pressing the submit button.
    $curPage = node(action => 'click', page => $homePage, by => 'name', match => 'btnG');
    is( $curPage->getTitleText( ), 'arch linux - Google Search', 'Page title match' );

    # Using XPath to get the first result in Google query. Should we want all the
    # results we could set the option all => 1 and get an array.
    my $element = node(page => $curPage, by => 'xpath', match => '//h3');
    # From a list of DOM child nodes we get the first.
    my $result = $element->getChildNodes( )->get( 0 );
    # As an alternative in this case we could use the ->toArray method:
    #my $result = $element->getChildNodes( )->toArray( )->[ 0 ];
    isa_ok($result, "${x}html::HtmlAnchor");
    # Notice how text content is already trimmed.
    is( $result->asText, 'Arch Linux', 'Got first result' );

    # The Google pager is a table.
    my $table = node(page => $curPage, match => 'nav');
    isa_ok( $table, "${x}html::HtmlTable" );

    # Read this table by rows.
    foreach my $row (@{table 'rows', $table}) {
        isa_ok( $row, "${x}html::HtmlTableRow" );
        note('Found row');

        my $j = '';
        foreach my $cell (@{table 'cells', $row}) {
            my $text = $cell->asText( );
            is ($text, 'Next', 'Found "Next"') if $text eq 'Next';
            is ($text, $j, "Found cell $j: $text") if $text ne 'Next';
            $j++;
        }
    }
}

done_testing();
