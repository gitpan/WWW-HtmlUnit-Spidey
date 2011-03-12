use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'WWW::HtmlUnit::Spidey',
    AUTHOR              => q{Antonio Bonifati <ninuzzo@cpan.org>},
    VERSION_FROM        => 'lib/WWW/HtmlUnit/Spidey.pm',
    ABSTRACT_FROM       => 'lib/WWW/HtmlUnit/Spidey.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'apache2')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Date::Parse'   => 0,
        'Log::Log4perl' => 1.20,
        'MIME::Types'   => 1.31,
        'Switch'        => 0,
        'Test::More'    => 0,
        'WWW::HtmlUnit' => 0.15,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'WWW-HtmlUnit-Spidey-*' },
);
