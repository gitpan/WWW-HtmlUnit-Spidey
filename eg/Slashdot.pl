#!/usr/bin/perl -w
# Demo of scraping with Spidey and WWW::HtmlUnit.
# Scrape a list of news and links from Slashdot home page.

use strict;
use warnings;
binmode STDOUT, ":utf8";

use lib '../lib';   # To make this run before Spidey is installed.
use WWW::HtmlUnit::Spidey;

my $b = browser 'ini';
my $p = browser 'go', $b, 'http://slashdot.org';

my $h = node(page => $p, by => 'xpath',
    match => '//h2[@class="story"]/*/a', all => 1);

logger->info(sprintf('Extracted %u headlines from Slashdot', $#{$h}+1));

print $_->asText, ' | ', $_->getHrefAttribute(), "\n" for @{$h};

browser 'fin', $b;
