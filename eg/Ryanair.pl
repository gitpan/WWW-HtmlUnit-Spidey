#!/usr/bin/perl -w
# Demo of scraping with Spidey and WWW::HtmlUnit.

# DISCLAIMER: this script should not be considered as an hacking attempt into
# the Ryanair.com web site. It justs uses this public service just like a
# normal web browser would do. When using this script you should still comply
# with all the terms of use of the Ryanair Website.
# You are the only responsible for any unlawful use of this code.

# TODOs:
# * Auto slide numbering.
# * Make a cross-product of results and order by price!
# * is it possible to use the TAB key and current selection to extract the same data?
#   How difficult is it compared to read the table?
# * Use the Spidey facility for pagination to fetch next week flights as well.

use strict;
use warnings;

use lib '../lib';   # To make this run before Spidey is installed.
use WWW::HtmlUnit::Spidey;
use Date::Calc (':all');

my ($b, $p);    # browser, page

sub next_date {
    my ($yy, $mm, $dd) = Today();
    ($yy, $mm, $dd) = Add_Delta_Days($yy, $mm, $dd, $_[0]);
    $dd = sprintf('%02u', $dd);
    $mm = sprintf('%02u', $mm);
    # These values are in exactly the same format as option values on site.
    return ($dd, "$mm$yy");
}

sub report {
    # kind of report: 1 for departure, 2 for return.
    my ($k) = @_;

    # Dates and prices of departure/return are in a table.
    my $t = node(match => "ttable$k", page => $p);

    print $k == 1 ? "DEPARTURES\n" : "RETURNS\n";

    # There is only one row (row and column index are 0-based).
    # Skip days with no flights.
    for (@{table 'cells', $t, 0 }) {
        eval {
            $_->getOneHtmlElementByAttribute('div', 'class', 'planeNoFlights');

            1;
        } or do {
            # Current cell does not contain a "No Flights" logo.
            my $f = $_->asText;
            $f =~ s/\n/ /g;
            print "$f\n";
        }
    }
}

$b = browser 'ini';

$p = browser 'go', $b, 'http://www.ryanair.com/en/booking/form';

# Slide the initial page with form default values.
file 'slide', '0-booking_form.html', $p;

# Departing from Edinburgh...
node(action => 'set', value => 'aEDI', match => 'sector1_o', page => $p);
# ...to Rome.
node(action => 'set', value => 'CIA', match => 'sector1_d', page => $p);

# Depart tomorrow...
my ($d, $m) = next_date(1);
node(action => 'set', value => $d, match => 'sector_1_d', page => $p);
node(action => 'set', value => $m, match => 'sector_1_m', page => $p);

# ...return in 1 week.
($d, $m) = next_date(7);
node(action => 'set', value => $d, match => 'sector_2_d', page => $p);
node(action => 'set', value => $m, match => 'sector_2_m', page => $p);

# Accept terms of use.
# To tick a checkbox, you just have to click on it.
node(action => 'click', match => 'acceptTerms', page => $p);

# Visual debug: how the booking form has been filled in.
file 'slide', '1-filled-in_booking_form.html', $p;

# Book Cheap Flights!
# This is an example where some JavaScript support is really useful.
# Infact the booking form won't submit without JS enabled.
$p = node(action => 'click', by => 'tag', match => 'button', page => $p);

# Slide first result page.
file 'slide', '2-results.html', $p;

report 1;
report 2;

