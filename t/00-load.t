#!perl

use Test::More tests => 1;

BEGIN {
    use_ok( 'WWW::HtmlUnit::Spidey' ) || print "Bail out!
";
}

diag( "Testing WWW::HtmlUnit::Spidey $WWW::HtmlUnit::Spidey::VERSION, Perl $], $^X" );
