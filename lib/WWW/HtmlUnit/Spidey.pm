package WWW::HtmlUnit::Spidey;

use warnings;
use strict;

### Some dependencies (other ones below).

# To build portable file paths and other things.
use File::Spec::Functions qw( catdir catfile rel2abs tmpdir );
use File::Basename;
# To create directory paths.
use File::Path;

### Configuration.
our %Conf;
BEGIN {
    %Conf = (
        # Generic.
        CACHE_DIR  => catdir(tmpdir(), 'spidey'),
        INLINE_DIR => catdir(tmpdir(), 'spidey', '_Inline'),
        LOG_CONF   => catfile(dirname(rel2abs(__FILE__)), 'Log4perl.conf'),
        LOG_DELAY  => 60,
        COOKIES    => 'cookies.base64',
        LOG        => 'spider.log',

        # Browser-level.
        BROWSER    => 'FIREFOX_3_6',
        CSS        => 0,
        TIMEOUT    => 1000 * 60,
        JS_FATAL   => 0,
        JS_TIMEOUT => 1000 * 4,
        SSL_CHECK  => 0,
    );

    # Inline won't create the build directory for us, this is annoying.
    # We need to do this at compile time, otherwise Inline will use the default
    # location.
    mkpath($Conf{INLINE_DIR});
}


### Other dependencies.

use Switch 'Perl6';

# Older versions have a bogus dependency on perl5i::2 which does not work
# with Perl 5.8. 0.14 lacks the ability to configure Inline::Java as we want.
# 0.15 is the latest stable version for the time being.
use WWW::HtmlUnit 0.15
    study     => [
        # These are HtmlUnit classes.
        'com.gargoylesoftware.htmlunit.NicelyResynchronizingAjaxController',
        # These are the only standard Java classes that we really need in Perl
        # code.
        'java.io.ByteArrayInputStream', 'java.io.ByteArrayOutputStream',
        'java.io.ObjectInputStream', 'java.io.ObjectOutputStream',
        'java.util.logging.Logger', 'java.util.logging.Level',
        'org.apache.commons.logging.LogFactory',
        'sun.misc.BASE64Decoder', 'sun.misc.BASE64Encoder',
        # Java code (classes) that is part of Spidey.  We tried to keep it to
        # the minimum that is only the things we cannot do calling Java from
        # Perl.
        'spidey.SkipFiles',
    ],
    # We need to provide an absolute path for loading our Java classes.
    # Alternatively we could put this any Java inline into this file like:
    # use Inline Java => q|
    #   ...java classes definition here
    # |;
    jars      => [ catfile(dirname(rel2abs(__FILE__)),
                   'jar', 'spidey-skipfiles-0.01.jar') ],
    DIRECTORY => $Conf{INLINE_DIR};

# Older versions of Inline::Java have problems with accessing Java classes.
# 0.53 is the latest stable version for the time being.
# This must come after including WWW::HtmlUnit because otherwise two _Inline
# directories will be created.
use Inline::Java 0.52_90 qw( cast coerce );

# For integrated fine-grained debugging facilities.  Previous Log4perl versions
# may lack the trace log level.  Latest ATTOW is 1.31!
use Log::Log4perl 1.20;

# To map a downloaded file mime-type to a well-known conventional extension.
# Old versions may lack new common extensions like docx.
use MIME::Types 1.31;

# For better error generation and logging using stack traces.
use Carp;

# For a date conversion facility offered by Spidey.
use Date::Parse;


### Exports.

use base 'Exporter';
our @ISA = qw( Exporter );
our $VERSION = '0.01';

# Keep all export lists in ascending alphabetical order.

# There are non-Tcl-like commands.
my @EXPORT_NONTCL = qw( $Conf date logger logdie node pages );
# We automatically export all and only those subs that a spider needs.
# Other utilities are rarely needed and  must be specifically qualified in
# order to be used from a spider code.  This was done on purpose to remember
# you that maybe what you are trying to do with them should be better handled
# here.
# NOTE: You may object that we are polluting the namespace of the module user,
# especially because we are exporting some short and common names.  But spiders
# really are intented to be written as Spidey submodules or separate modules
# that deals only with spidering, thus this is not a concern.
our @EXPORT = (@EXPORT_NONTCL, qw( browser file form table ));
our @EXPORT_OK = qw( browser_cookies browser_fin browser_go browser_ini
    browser_js file_log file_path file_read file_slide file_type file_write
    form_hidden form_sel form_submit table_cell table_debug table_read table_row);
# If you do not like the Tcl-ish syntax reimplemented in Perl as:
#     command 'subcommand'
# you can use:
#     command_subcommand
# This is limited to the first level of subcommands.  You will still have to
# say:
#     command_subcommand 'subsubcommand'
our %EXPORT_TAGS = (NOTCL => [ @EXPORT_NONTCL, @EXPORT_OK ]);


### Functions.

# We need to define this to support configuration options after 'use'.
# Ref. http://perldoc.perl.org/Exporter.html#Exporting-without-using-Exporter's-import-method
# and http://www.perlmonks.org/?node_id=57816
sub import {
    my @exports;
    for (@_) {
        if (ref($_) eq 'HASH') {
            # Param hash found.
            # Merge hashes. See: http://www.perlmonks.org/?node_id=612615
            @Conf{keys %$_} = values %$_;
        } else {
            push @exports, $_;
        }
    }

    # Any code here will be executed at runtime to initialize the library after
    # configuration has been overriden. Namely only the logger needs to be
    # initialized.

    # Since we use Spidey in Log4perl files to get the path of log files, we
    # need a way to avoid an infinite loop. Log::Log4perl->initialized() does
    # not help here because it is only set afterwards, when the initialization
    # has been completed.
    unless ($Conf{NO_LOG4PERL}) {
        # Make sure the cache path exists.  This should be done before calling
        # get_logger!
        mkdirp(spath());

        # Initialize the logger.
        # Reload the configuration file every LOGDELAY seconds.
        Log::Log4perl->init_and_watch($Conf{LOG_CONF}, $Conf{LOG_DELAY});
    }

    $_[0]->export_to_level(1, @exports); 
}

# Get a Log4perl logger to log messages on behalf of the current module or main
# program using Spidey. This facility is used both internally into Spidey and
# offered to programs that use our library. Unfortunately this is not a pure
# function and all other functions that use it won't be pure. 
# It cannot be made a package-wide static (e.g. a module variable) because it
# will not get changed when Spidey is included more than one time.
# Using the OO approach with a constructor to initialize this (or doing that in
# browser_ini) is not appropriate either because I want logging to be
# configured even before a browser is created o new is called (it may be useful
# to log something before).
# Therefore I want Spidey to configure Log4perl for the user at compile time to
# keep things simple. Thereafter there is no point in asking the user to pass a
# logger to Spidey: Spidey can figure it out by itself and this is efficient to
# do.  If it weren't for the logging and debugging code, Spidey would be a pure
# functional library. We could say that is almost pure, which IMHO is better
# than an object oriented module with a lot of state. In other words I avoided
# any state information and thus objects where to keep it, but I had to include
# some non-pure functions, although only for logging and debugging features.
#
# See also:
# http://log4perl.sourceforge.net/releases/Log-Log4perl/docs/html/Log/Log4perl/FAQ.html#79bdb
# But as said before we cannot easily let the user to configure the logger because we need to
# use it here as well.
sub logger {
    # Get an instance of a logger specific to the calling spider.
    # get_logger is a singleton, it should be quite fast!
    Log::Log4perl->get_logger(sp());
}

sub logdie {
    my ($m) = @_;

    # You can get a Java stack trace printed to STDERR
    # calling $@->printStackTrace(), but what's the use?
    # We are not debugging Inline::Java :)
    # Better a Perl stack trace!

    # But before dying log this long mess!
    logger->fatal("$m\n" . Carp::longmess);

    confess $m;
}

# Just a facility to generate an error when a subcommand (default) or
# subsubcommand or option, etc. is not recognized.  It ensures error message
# uniformity.
sub invalid {
    my %arg = @_;
    my ($a, $e, $s) = @arg{qw( action entity subcmd )};
    $e = 'subcommand' unless defined $e;
    $s = [ $s ] if ref($s) ne 'ARRAY';

    my $f = shift @{$s};
    my $c = join ', ', map "'$_'", @{$s};
    logdie("Invalid $e '$a' to: $f $c");
}

sub browser_go {
    my ($b, $u, @p) = @_;

    my $p;

    eval {
        # See perldoc -f eval for rationale.
        local $SIG{'__DIE__'};

        $u = @p ? sprintf($u, @p) : $u;
        $p = $b->getPage($u);

        logger->info("Went to: $u");

        # TODO: experimental APIs we may want to use when they become stable at a future date.
        # $b->waitForBackgroundJavaScript(1000 * 60);
        # $b->waitForBackgroundJavaScriptStartingBefore(1000 * 60);

        1;
    } or do {
        logdie("Cannot go to page '$u'");
    };

    return $p;
}

sub browser_js {
    my ($b, $s) = @_;

    given ($s) {
        when /0|off/i {
            $b->setJavaScriptEnabled(0);
            logger->info('Javascript is OFF');

            last;
        }

        when /1|on/i {
            $b->setJavaScriptEnabled(1);
            logger->info('Javascript is ON');

            last;
        }

        default { invalid(entity => 'state', action => $s, subcmd => ['browser', 'js']); }
    }
}

sub browser_cookies {
    my ($a, $b) = @_;

    given ($a) {
        when /save/i {
            jserialize($Conf{COOKIES}, $b->getCookieManager()->getCookies(), 4);

            last;
        }

        when /load/i {
            return 0 unless -f file_path($Conf{COOKIES});

            eval {
                local $SIG{'__DIE__'};

                $b->getCookieManager()->addCookie($_)
                    for @{cast('java.util.Set',
                        junserialize($Conf{COOKIES}, 5))->toArray()};

                1;
            } or do {
                return 0;
            };

            return 1;
        }
        
        default { invalid(action => $a, subcmd => ['browser', 'cookies']); }
    }
}

sub browser_ini {
    my %arg = @_;
    my ($c, $e, $s, $f, $j, $t) = @arg{qw( css emu ssl_check js_fatal js_timeout timeout )};
    $c ||= $Conf{CSS};         # CSS support.
    $e ||= $Conf{BROWSER};     # Default browser to emulate.
    $s = $Conf{SSL_CHECK} unless defined $s;   # SSL certificate checking.
    $f ||= $Conf{JS_FATAL};    # Default behaviour on script errors.
    $j ||= $Conf{JS_TIMEOUT};  # Default JavaScript time-out.
    $t ||= $Conf{TIMEOUT};     # Default HTTP time-out.

    # Note we shut off all the warning messages.  These specific warnings
    # usually don't really make sense in the context of web scraping, but are
    # important when HtmlUnit is used for testing purposes.  This is not the
    # target of Spidey, currently but it may be at some future date and we will
    # change NoOpLog with Log4JLogger.
    # TODO: when there is some unsupported JS it may be still be of some use to
    # have the chance to get these errors even if we are doing web scraping and
    # we cannot fix messy upstream JavaScript.  E.g. just to report JS bugs to
    # the HtmlUnit development team or see if the problematic JS is essential.
    WWW::HtmlUnit::org::apache::commons::logging::LogFactory
        ->getFactory()->setAttribute('org.apache.commons.logging.Log',
            'org.apache.commons.logging.impl.NoOpLog');
    WWW::HtmlUnit::java::util::logging::Logger
        ->getLogger('com.gargoylesoftware.htmlunit')
        ->setLevel($WWW::HtmlUnit::java::util::logging::Level::OFF);
    WWW::HtmlUnit::java::util::logging::Logger
        ->getLogger('org.apache.commons.httpclient')
        ->setLevel($WWW::HtmlUnit::java::util::logging::Level::OFF);

    my $b = WWW::HtmlUnit->new($e);
    $b->setThrowExceptionOnScriptError($f);
    $b->setJavaScriptTimeout($j);
    $b->setUseInsecureSSL(! $s);
    $b->setTimeout($t);
    $b->setCssEnabled($c);
    # Make all AJAX calls synchronous, for simplicity.  See here:
    # http://old.nabble.com/Please-confirm-expected-behavior-of-NicelyResynchronizingAjaxController-td18499842.html
    $b->setAjaxController(new
        WWW::HtmlUnit::com::gargoylesoftware::htmlunit::NicelyResynchronizingAjaxController()
    );
    # By default popups are blocked.  See:
    # http://htmlunit.sourceforge.net/apidocs/com/gargoylesoftware/htmlunit/WebClient.html#setPopupBlockerEnabled(boolean)

    # An empty message, but useful in practice as a marker to locate the
    # beginning of a spider execution into the log file.
    logger->info();

    return $b;
}

sub browser_ex {
    my ($b, $r) = @_;  # browser, exclusion-list regex

    # HtmlUnit requires us to wrap web connections and do not execute calls to
    # certain kind of files. This can only be done in Java, not in Perl.
    $b->setWebConnection(new WWW::HtmlUnit::spidey::SkipFiles->list($b, $r));
}

sub browser_fin {
    my $b = shift;
    # Closes all opened windows, stopping all background JavaScript
    # processing, if any.
    $b->closeAllWindows();

    # An empty message, but useful in practice as a marker to locate the end of
    # a spider execution into the log file.
    logger->info();
}

sub browser {
    my $a = shift;

    # Put most often used calls before.
    given ($a) {
        when /js/i {
            return browser_js @_;
        }

        when /go/i {
            return browser_go @_;
        }

        when /cookies/i {
            return browser_cookies @_;
        }

        when /ini/i {
            return browser_ini @_;
        }

        when /fin/i {
            return browser_fin @_;
        }

        when /ex/i {
            return browser_ex @_;
        }

        default { invalid(action => $a, subcmd => 'browser'); }
    }
}   

sub date {
    my ($date, %arg) = @_;

    # Regex chunks to match dates.
    my ($day, $sep, $month, $h_re, $m_re, $s_re) = qw/(0?[1-9]|[12]\d|3[01])
        ([^\d]) (0?[1-9]|1[012]) ([01]?\d|2[0-3]) ([0-5]?\d)
        (0?[1-9]|[1-5][0-9])/;

    # Replace all white space around separator with nothing.
    $date =~ s/(\d)\s*$sep\s*(\d)/$1$2$3/go;

    # Strip blank space from the end to avoid problems with strptime.
    $date =~ s/\s+$//g;

    # Swap from dd-mm- format to mm-dd- (used by Date::Parse)
    # unless we know date is already in American format.
    $date =~ s/\b$day$sep$month$sep/$3$2$1$4/o unless $arg{monthfirst};

    # Cover cases like 00/01/01 - yy/mm/dd.  This is an unambiguous date to be
    # interpreted as 2000-01-01.  It's about dates in the past not very
    # commonly used but this routine tries to do his best with every date in
    # general.
    $date =~ s/\b00$sep$month$sep$day/2000$1$2$3$4/o;

    # Replace a possible dash separating date from time
    # with space in that strptime does not like it.
    $date =~ s/-$h_re:$m_re(:$s_re)?/ $1:$2$3/o;

    # The main work is done by a function imported from Date::Parse.
    my ($ss, $mi, $hh, $dd, $mm, $yy) = Date::Parse::strptime($date);
    return unless defined $yy && defined $mm && defined $dd;

    # strptime never puts a leading zero before a month number, uses 0-based
    # counting and does no range checking, so this check if required.
    return unless $mm =~ /^(\d|1[01])$/;

    # A leading zero can be or not.  Range checking is also needed and
    # accomplished by this regex.
    return unless $dd =~ /^(0?[1-9]|[12][0-9]|3[01])$/;

    # A leading zero can be or not.  No range checking is done by strptime.
    $hh = 0 unless defined $hh && $hh =~ /^$h_re$/o;
    $mi = 0 unless defined $mi && $mi =~ /^$m_re$/o;
    my $has_ss = defined $ss && $ss =~ /^$s_re$/o;

    # Build the date and, optionally, the time components.
    my @date;

    # When ambiguous two-digit year values are used, software like MySQL
    # usually use a conventional transition point of 1970; it interprets values
    # from 00 to 69 as the years 2000 to 2069, and values from 70 to 99 as the
    # years 1970 to 1999 instead of 2070 to 2099.  We will do the same here.
    push @date, sprintf('%d-%02d-%02d', $yy < 70 && index($date, "19$yy") == -1
            ? $yy + 2000 : ($yy < 1000 ? $yy + 1900 : return), $mm + 1, $dd);

    push @date, sprintf('%02d:%02d' . ($has_ss ? ':%02d' : ''), $hh, $mi, $ss)
        unless $arg{notime};

    # Return the date or date-time.
    join ' ', @date;
}

sub form_sel {
    my ($a, $e, $v) = @_;

    given ($a) {
        when /opt/i {
            # Select either one or multiple options.
            $v = [ $v ] unless ref($v) eq 'ARRAY';
            my $p;
            $p = $e->setSelectedAttribute(coerce('java.lang.String', $_),
                coerce('boolean', 1)) for @$v;
            return $p;
        }

        when /setmul/i {
            # Enable multiple selection.
            $e->setAttribute('multiple', '');
            return $e->setAttribute('size', '6');
        }

        when /desel/i  {
            if ($e->isMultipleSelectEnabled()) {
                my $p;
                $p = $e->setSelectedAttribute($_, coerce('boolean', 0))
                    for @{$e->getSelectedOptions()->toArray()};
                return $p;
            }
            return;
        }

        default { invalid(action => $a, subcmd => ['form', 'sel']); }
    }
}

# Ideally I would like to use the HtmlUnit API for this task, but Java
# constraints break my balls all the time.  Since we cannot instantiate
# HtmlHiddenInpute we have to use Javascript.
# http://stackoverflow.com/questions/4972995/in-java-htmlunit-how-do-i-add-an-hidden-input-to-a-form
# A clumsy Java hash must be used to set the node attributes.
#my $a = new WWW::HtmlUnit::java::util::HashMap();
#$a->put('name', $n);
#$a->put('value', $v);
#$f->appendChild(new
#    WWW::HtmlUnit::com::gargoylesoftware::htmlunit::html::HtmlHiddenInput(
#        $p, $a));
sub form_hidden {
    my %arg = @_;

    my ($b, $p, $by, $m, $v, $c, $n) = @arg{qw( browser page by match value caw name )};
    $c = 1 unless defined $c;   # By default croak loudly on errors!
    $by ||= 'id';   # Default is getting/setting by a form by ID.

    my $f;
    given ($by) {
        when /id/i {
            $f = "getElementById('$m')";

            last;
        }

        when /name/i {
            # This will work as well, but we go for the simpler way.
            #$f = "getElementsByName('$m')[0]";
            $f = $m;

            last;
        }

        default { invalid(entity => 'select method', action => $by, subcmd => ['form', 'hidden']); }
    }

    my $j = $b->isJavaScriptEnabled();
    # Enabling JavaScript after page loading does really cost a little.
    $b->setJavaScriptEnabled(1) unless $j;

    my $s;    # Script result.
    eval {
        local $SIG{'__DIE__'};

        $s = $p->executeJavaScript(<<JS
{
    var d = document,
        i = d.createElement('input');
    with (i) {
        name = '$n';
        type = 'hidden';
        value = '$v';
    }
    d.$f.appendChild(i);
}
JS
        );

        1;
    } or do {};

    my $e = sprintf(
        '<input type="hidden" name="%s" value="%s"> into <form %s="%s">',
        $n, $v, $by, $m);
    if ($s) {
        logger->info("Injected $e");
    } else {
        # Unfortunately if there's an error it seems that we get undef instead of a
        # ScriptResult object to call getJavaScriptResult on.  Anyway we can be
        # sure the above JavaScript is correct: the only cause can be a missing
        # matching and we can provide a very useful warning/error message for
        # that (better than the Java exception we are muting.
        my $e = "Cannot add an $e";
        if ($c) {
            logdie($e);
        } else {
            logger->warn($e);
        }
    }

    $b->setJavaScriptEnabled(0) unless $j;

    # Returns the modified page.
    return $s->getNewPage() if $s;
    # Return the unmodified page.
    return $p;
}

# That's a pity that access to the internal submit method has been removed from HtmlForm.
# http://old.nabble.com/2.7-missing-form.submit()-and-forms-with-no-buttons-td28390014.html
# It means that we must enable JavaScript for this hack that really shouldn't be one.
sub form_submit {
    my %arg = @_;

    my ($b, $p, $by, $m, $c) = @arg{qw( browser page by match caw )};
    $c = 1 unless defined $c;   # By default croak loudly on errors!
    $by ||= 'id';   # Default is getting/setting by a form by ID.

    my $f;
    given ($by) {
        when /id/i {
            $f = "getElementById('$m')";

            last;
        }

        when /name/i {
            $f = $m;

            last;
        }

        default { invalid(entity => 'select method', action => $by, subcmd => ['form', 'submit']); }
    }

    my $j = $b->isJavaScriptEnabled();
    # Enabling JavaScript after page loading does really cost a little.
    $b->setJavaScriptEnabled(1) unless $j;

    my $s;    # Script result.
    eval {
        local $SIG{'__DIE__'};

        $s = $p->executeJavaScript("document.$f.submit()");

        1;
    } or do {};

    unless ($s) {
        my $e = sprintf('Cannot submit <form %s="$m">', $by, $m);
        if ($c) {
            logdie($e);
        } else {
            logger->warn($e);
        }
    }

    $b->setJavaScriptEnabled(0) unless $j;

    # Returns the modified page.
    return $s->getNewPage() if $s;
    # Return the unmodified page.
    return $p;
}

sub form {
    my $a = shift;

    # Put most often used calls before.
    given ($a) {
        when /hidden/i {
            return form_hidden @_;
        }

        when /sel/i {
            return form_sel @_;
        }

        when /submit/i {
            return form_submit @_;
        }

        default { invalid(action => $a, subcmd => 'form'); }
    }
}

sub node {
    my %arg = @_;

    my ($a, $e, $p, $by, $m, $v, $c, $n) = @arg{qw( action all page by match value caw )};
    logdie('page param is mandatory and must be an HtmlPage') unless ref($p) =~ /HtmlPage/;
    $a ||= 'get';   # Default action.
    $c = 1 unless defined $c;   # By default croak loudly on errors!
    $e = 0 unless defined $e;   # By default fetch only one node.
    $by ||= 'id';   # Default is getting/setting by ID.

    # Always use thread-safe exception handling, not eval followed by if.
    # See: http://en.wikipedia.org/wiki/Exception_handling_syntax#Perl
    eval {
        # See perldoc -f eval for rationale.
        local $SIG{'__DIE__'};

        given ($by) {
            when /xpath/i {
                $n = $e ? $p->getByXPath($m)->toArray() :
                    $p->getFirstByXPath($m);

                last;
            }

            when /id/i {
                $n = $p->getElementById($m);

                last;
            }

            when /name/i {
                $n = $e ? $p->getElementsByName($m)->toArray() :
                    $p->getElementByName($m);

                last;
            }

            when /tag/i {
                $n = $p->getElementsByTagName($m)->toArray();
                $n = $n->[0] unless $e;

                last;
            }

            # The HtmlUnit DOM API has also CSS selector support!
            when /css/i {
                $n = $p->querySelector($m);

                last;
            }

            default { invalid(entity => 'select method', action => $by, subcmd => 'node'); }
        }

        # Node not found?
        if (! $n) {
            # Caw if you have to!
            # TODO: more informative message?
            logdie('Node not found') if $c;

            $p = 0; # Set the return value to false.
            # Get out of this "try" block with no error.
            return 1;
        }

        # As a small optimization put most used actions before.
        # Anyway there will never be a high number of subcommands.  If it were
        # this way, dispatch tables and subroutine references would be needed:
        # http://docstore.mik.ua/orelly/perl2/advprog/ch04_02.htm#ch04-30761
        # We prefer a switch because with dispatch tables no approximate
        # matching can be done.
        given ($a) {
            when /set/i {
                if (ref($n) =~ /HtmlSelect/) {
                    if (ref($v) eq 'ARRAY' && @$v > 1) {
                        # Some sites may have a JavaScript GUI control that turns a
                        # single select into a multiple one.  We reproduce the
                        # JS behaviour here in order to be able to disable JS
                        # and gain some perfomance.
                        form_sel 'setmul', $n;

                    }

                    # Deselect any option selected by default, usually only one.
                    form_sel 'desel', $n;

                    # select all wanted options.
                    $p = form_sel 'opt', $n, $v;
                } else {
                    $p = $n->setValueAttribute($v);
                }

                last;
            }

            when /click/i {
                $p = $n->click;

                last;
            }

            when /get/i {
                # Default action is get.  Its return value is the node(s)
                # itself.
                $p = $n;

                last;
            }
            
            default { invalid(action => $a, subcmd => 'node'); }
        }

        # Get out of this "try" block with no error.
        1;
    } or do {
        # TODO: a more precise error message could be provided.
        # To be done when we implement verbose logging at level TRACE.
        logdie('Cannot get/set values or click an HTML node. Java exception: '
            . $@->getMessage);
    };

    # Returns either the modified page or a node or false if none is found.
    return $p;
}

sub sp {
    my $c;

    for (my $i = 0; ($c = caller($i)) eq __PACKAGE__; $i++) { }
    $c;
}

sub table_read {
    my %arg = @_;

    my ($o, $t, $hl, $fl, $inc, $m, $k, $v) = @arg{qw( out table header footer inc map key value )};
    $hl = 1 unless defined $hl; # Default to one header line.
    $fl = 0 unless defined $fl; # Default to no footer lines.
    $inc ||= 1; # Default to extract both odd and even rows.

    # Built a table (hash) to quickly look up the column number given the
    # column title.
 
    # Read column headers on the last header row (row indexes are 0-based). 
    my $r = $t->getRow($hl - 1);
    my %col;    # This hash will tell the numeric column index for each piece of data.
    my $j = 0;  # The initial column index is 0.

    # Since we are in Perl we have to use an iterator explicitely, there
    # is no for-each Java loop equivalent and toArray does not work here.
    # TODO: alternatively HtmlTableRow::getCells may be used with toArray.
    for (my $i = $r->getCellIterator; $i->hasNext; ) {
        # We do not bother skipping fields we will not
        # extract since this is only a lookup table.
        $col{$i->next->asText} = $j++;
    }

    # Extract required rows and columns of data using the lookup table.
    my $lim = $t->getRowCount - $fl;
    my @info = keys %$m;    # Columns to extract.
    my $a = 0;   # Initial automatic ID.  Also used to count rows inserted.
    # Skip header rows.
    for (my $i = $hl; $i < $lim; $i += $inc) {
        # By default use a numeric ID, but user code may change that.
        my $id = $a++;
        # Here we use a lambda function or closure instead of a plain reference
        # to a function.
        # Care has been taken to make the exception trap atomic and thus
        # thread-safe.
        eval {
            local $SIG{'__DIE__'};
            # TODO: the function prototype needs to be extended for future needs.
            $id = $k->($i, $id); 
            1;
        } or do {
            logdie("The custom code to compute the key died with error: $@");
        } if $k;

        for my $f (@info) {
            # Java null values are turned into Perl undefs.
            my $c = $t->getCellAt($i, $j = $col{$f});

            if (defined $c) {
                # Map table column names ($f) to user field names ($uf).
                my $uf = $m->{$f};
                # Note how we pass a simbolic reference to the custom user
                # code.
                my $p = \$o->{$id}->{$uf};
                my $t = $c->asText;

                if ($v) {
                    eval {
                        local $SIG{'__DIE__'};
                        # TODO: change argument order putting parameters that
                        # are likely to be ignored at the end.
                        $v->($uf, $p, $f, $t, $id, $o);
                        1;
                    } or do {
                        logdie("The custom code to compute the value died with error: $@");
                    };
                } else {
                    # If no custom code is provided, the cell text is always
                    # saved unchanged.
                    $$p = $t;
                }
            } else {
                logdie("Cannot find '$f' field in table anymore at ($i, $j)");
            }
        }
    }
    # Return the number of new rows inserted.
    $a;
}

sub table_row {
    my ($t, $r) = @_;

    if (defined $r) {
        eval {
            $r = $t->getRow($r);

            1;
        } or do {
            logdie("Cannot get table row #$r");
        };
        return $r;
    }

    # Returns an array of references to HtmlTableRow objects.
    return $t->getRows()->toArray();
}

sub table_cell {
    my ($t, $r, $c) = @_;

    if (ref($t) =~ /HtmlTableRow/) {
        return $t->getCells->toArray() unless defined $r;

        eval {
            $c = $t->getCell($r);

            1;
        } or do {
            logdie("Cannot get table cell #$r");
        };
    } else {
        return $t->getCellAt($r, $c) if defined $c;

        eval {
            # We could reuse table_row here, but it would be a little thing and we
            # want a custom error message.
            $c = $t->getRow($r)->getCells->toArray();

            1;
        } or do {
            logdie("Cannot get all table cells of row #$r");
        };
    }
    return $c;
}

sub table_debug {
    my $html = <<'HTML';
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN">
<html>
<head>
<meta name="generator" content="Spidey">
<title>Table with coordinates</title>

<style type="text/css">
  td:first-line { font-weight: bold }
</style>
</head>
<body>
<table border="1" summary="table with added coordinated">
HTML

    my $i = 0;
    for my $row (@{$_[0]->getRows->toArray()}) {
        my $j = 0;
        $html .= "<tr>\n";
        for my $cell (@{$row->getCells->toArray()}) {
            my $text = $cell->asText( );
            $html .= "<td>$i,$j<br>\n$text</td>\n";
            $j++;
        }
        $html .= "</tr>\n";
        $i++;
    }

    $html .= <<'HTML';
</table>
</body>
</html>
HTML
}

sub table {
    # Put most often used calls before.
    given (my $a = shift) {
        when /read/i {
            return table_read @_;
        }

        when /row/i {
            return table_row @_;
        }

        when /cell/i {
            return table_cell @_;
        }

        when /debug/i {
            return table_debug @_;
        }

        default { invalid(action => $a, subcmd => 'table'); }
    }
}

sub path {
    catfile($Conf{CACHE_DIR}, @_);
}

sub spath {
    path(map lc, split '::', sp());
}

sub file_path {
    catfile(spath(), $_[0]);
}

sub file_read {
    my $p = file_path($_[0]);
    # This is a way fast file slurping implementation.  See:
    # http://www.perlmonks.org/?node_id=1952
    open my $h, '<', $p or logdie("Can't open '$p' for reading: $!");
    # This is important also when using sysread!
    binmode $h;
    sysread $h, my $f, -s $h;
    close $h;

    $f;
}

sub file_write {
    my ($a, $p, $o) = @_;   # action, path and object (page/string)

    $p = file_path($p);
    mkdirp(dirname($p));
    open my $h, '>', $p or logdie("Can't open '$p' for writing: $!");
    logger->info("Writing file '$p'");

    my $x = ref($o) =~ /Page/;  # Either HtmlPage or UnexpectedPage
    given ($a) {
        when /html/i {
            return $h unless defined $o;

            # TODO: sometimes we get a "Wide character in print" benign
            # warning.
            print $h $x ? $o->asXml : $o;
            last;
        }

        when /text/i {
            return $h unless defined $o;

            print $h $x ? $o->asText : $o;
            last;
        }

        when /bin/i {
            binmode $h;
            return $h unless defined $o;

            # TODO: use getContentAsStream() for scalability large files
            # See also here: http://permalink.gmane.org/gmane.comp.java.htmlunit.devel/16887
            print $h $x ? $o->getWebResponse()->getContentAsString() : $o;
            last;
        }

        default { invalid(action => $a, subcmd => ['file', 'write']); }
    }

    close $h or logdie("Unable to close '$p': $!");
}

sub file_slide {
    my ($p, $o) = @_;

    # TODO: provide an option for those who few want to save a page with
    # images.  See:
    # http://htmlunit.sourceforge.net/apidocs/com/gargoylesoftware/htmlunit/html/HtmlPage.html#save(java.io.File)
    file_write('html', $p, $o) if logger->is_debug();
}

sub file_type {
    my ($p, @e) = @_;

    $, = '/';   # Field separator to use when printing an array.
    logger->info('Accepted extensions: ' . @e ? @e : 'any');

    # Alternatively we could not trust the site and detect the file type by
    # using the File::Type CPAN module.  But that seems to be overmuch.
    my $c = $p->getWebResponse()->getContentType();

    # Map mime-type to one most common respective file extension. 
    my $mt = MIME::Types->new;
    my $t = $mt->type($c);
    my $e;
    if (defined $t) {
        # We take the first extension which should be the more common one.
        ($e) = $t->extensions;
    } else {
        # Rather than mapping missing entries by ourselves it would be better
        # to contact the Mime::Type developer first.
        logger->warn("Unknown mime-type '$c', extension 'bpk' used. If you think it should be supported please contact Spidey developers to map an appropriate extention to it.");
        # Ref. http://www.file-extensions.org/bpk-file-extension-unknown-binary-file
        $e = 'bpk';
    }

    return $e if !@e || grep $_ eq $e, @e;
    logdie("Unexpected content/type '$c'. Not a @e");
}

sub mkdirp {
    my ($p) = @_;

    # make_path is preferred in newer File::Path versions.
    unless (-d $p) {
        # The first time this is called, the logger does not exist yet.
        # To snap out this sort of chicken-egg problem an "if" is required.
        # We will not be able to log the creation of the first call to mkdirp,
        # namely the making of the spider directory inside the root of Spidey.
        logger->trace("created directory '$p'") if Log::Log4perl->initialized();
        mkpath($p);
    }
}

sub file_log {
    my ($n) = @_;
    $n = '' unless defined $n;

    my $p = path(map(lc, split('::', $n)), $Conf{LOG});
    # This is needed otherwise Log4perl dies at startup if the dir does not
    # exist.
    mkdirp(dirname($p));

    $p;
}

sub file {
    my $a = shift;

    # Put most often used calls before.
    given ($a) {
        when /write/i {
            return file_write @_;
        }

        when /slide/i {
            return file_slide @_;
        }

        when /type/i {
            return file_type @_;
        }

        when /log/i {
            return file_log @_;
        }

        when /path/i {
            return file_path @_;
        }

        when /read/i {
            return file_read @_;
        }

        default { invalid(action => $a, subcmd => 'file'); }
    }
}

sub jserialize {
    my ($f, $o) = @_;    # file and object

    # In Java you would write (saving raw objects, without any encoding):
    #
    # ObjectOutput out = new ObjectOutputStream(new FileOutputStream("cookie.file"));
    # out.writeObject(b.getCookieManager().getCookies());
    # out.close();
    #
    # but since I want to use the file_write facility a bit more work is
    # involved:
    # http://www.velocityreviews.com/forums/t561666-how-to-serialize-a-object-to-a-string-or-byte.html

    # Yep, Java is very ugly, but fortunately we are encapsulating the crap.

    # There could be an IOException but it is unlikely to happen so we don't
    # bother catching it from Perl.
    my $b = new WWW::HtmlUnit::java::io::ByteArrayOutputStream();
    new WWW::HtmlUnit::java::io::ObjectOutputStream($b)
        ->writeObject(cast('java.lang.Object', $o));

    file_write('text', $f, new WWW::HtmlUnit::sun::misc::BASE64Encoder()
        ->encode($b->toByteArray));
}

sub junserialize {
    # For comparison, here is the corresponding Java code (without any encoding).
    #
    # File file = new File("cookie.file");
    # ObjectInputStream in = new ObjectInputStream(new FileInputStream(file));
    # Set<Cookie> cookies = (Set<Cookie>) in.readObject();
    # in.close();
    #
    # Iterator<Cookie> i = cookies.iterator();
    # while (i.hasNext()) {
    #    wc.getCookieManager().addCookie(i.next());
    # }

    # Here we want to use file_read and in order to interface with the
    # strong-typed world of Java we were forced to use an ASCII encoding like
    # Base64.  Strong typing always makes life harder!  There could be an
    # IOException or a ClassNotFoundException.  Both are unlikely to happen so
    # we don't bother catching them from Perl.
    new WWW::HtmlUnit::java::io::ObjectInputStream(
        new WWW::HtmlUnit::java::io::ByteArrayInputStream(
            new WWW::HtmlUnit::sun::misc::BASE64Decoder()->decodeBuffer(
                coerce('java.lang.String', file_read($_[0]))
            )
        )
    )->readObject();
}

sub pages {
    my %arg = @_;

    my ($r, $n, $l) = @arg{qw/read next limit/};

    for (my ($i, $j) = (0, 1); ; $j++) {    # Initialize output hash length and page number.
        my $k;  # Number or records read.
        eval {
            local $SIG{'__DIE__'};
            $i += $k = $r->(); 
            1;
        } or do {
            logdie("The custom code to read a page died with error: $@");
        };

        logger->info("Extracted $k records from page $j, got $i so far");

        # Do we have enough results?
        if ($i >= $l) {
            logger->info("Enough results: got $i, requested $l");
            last;
        }

        # Go to the next page, if any.
        eval {
            local $SIG{'__DIE__'};
            unless ($n->()) {
                logger->info('No next page');
                # TODO: Is there a way to get rid of the benign warning
                # "Exiting eval via last" ?
                last;
            }

            1;
        } or do {
            logdie("The custom code to go to the next page died with error: $@");
        };
    }
}

# Return a true value to signal correct module loading.
1;  # End of WWW::HtmlUnit::Spidey

__END__


=head1 NAME
 
WWW::HtmlUnit::Spidey - A mostly declarative language and tools for writing web
spiders with JavaScript support.

=head1 VERSION

Version 0.01

B<WARNING>: this is still a WIP.  Some aspects of the interface can change
without notice.

=head1 SYNOPSIS

  binmode STDOUT, ":utf8";
  use WWW::HtmlUnit::Spidey;

  my $b = browser 'ini';
  my $p = browser 'go', $b, 'http://slashdot.org';

  my $h = node(page => $p, by => 'xpath',
      match => '//h2[@class="story"]/*/a', all => 1);

  logger->info(sprintf('Extracted %u headlines from Slashdot', $#{$h}+1));

  print $_->asText, ' | ', $_->getHrefAttribute(), "\n" for @{$h};

  browser 'fin', $b;

=head1 DESCRIPTION

Spidey is a generic web scraping library. 

This library will make you write web spiders easily, using exactly the same
workflow a manual user would follow, disguising your spider as a real user and
abstracting you from the details of how the Web works as much as possible.  It
also offers some basic facilities for easy data extraction and conversion.  To
be a "spiderman" you only need to have a general understanding of how the Web
works and be familiar with some XPath and/or CSS selectors.  No knowledge of
JavaScript, nitty-gritty of HTML or HTTP is required.

For the sake of high cohesion this library should implement all features
intended to be shared and reused by all spiders.  If any feature you need for
your application is missing, please contact the developers asking to add it.

=head1 IMPLEMENTATION

For all Java methods used please refer to:

  http://htmlunit.sourceforge.net/apidocs/

Spidey strives to not use HtmlUnit internal APIs: we mostly call only stable
public methods which are safe to use.

=head2 INTERFACE DESIGN AND TRAITS

This is a multi-paradigm procedural module using ideas from both declarative,
functional and Object Based Programming.

Inspired by Tcl commands and subcommands Spidey often provides some sort of
macro instructions to simplify syntax.  Named parameters are used whenever they
number of configuration options is high enough: make calls easier to read and
write because one does not have to remember both parameter order and meaning.

The underlying library used to crawl the web is HtmlUnit, because there were no
Perl alternatives offering JavaScript support ATTOW.  HtmlUnit is implemented
in Java which is a type-nightmare.  Therefore we localize any needed casting
from Perl to Java types here as well as any Java idiosyncrasy.

I've chosen to use lambda functions to pass some code snippets for full
configurability and code reuse because they are more powerful than plain
subroutine references: they can reference lexical (my) variables from the
caller's scope, be defined in situ and nested.

=head2 ERROR HANDLING

Uncaught Java exceptions will terminate your Perl script so something must be
done about them.  From a Perl programmer's point of view it is pointless to
report Java gibberish (with the sole exception of meaningful HtmlUnit exception
messages, no pun intented).  Java stack traces are not useful since we are
using Java from Perl: they will tell you what happened inside <Inline::Java>,
something you really do not care of, because the bug is highly likely to
be in your code or something in the site you are scraping changed.  We could
try to avoid Java exception going off but this requires implementing a lot of
checking that will clutter up the Spidey code.  Moreover it it difficult to
predict and take account of all the many ways HtmlUnit can fail.

The simplest solution is to just wrap function bodies into an eval, allowing
both Java and Perl exceptions to happen at runtime, and caught them to provide
meaningful Perl stack traces along with any other useful error message we can
hopefully get from Java and log all with Log4perl.  This keeps our code simpler
and will provide some useful post-mortem debug info.  In terms of performance,
any hit that the use of eval has on our code will be completely negligible
compared to the delays involved in waiting for any web server (specifically
because we always use eval BLOCK and not eval EXPR so that the code is compiled
only once).  Server latency is the real bottleneck.

Moreover for simplicity we always stop at the first error.

=head2 CONFIGURATION

All the non-browser specific options, that is those shared between all browsers
can only be overridden via C<use> options, that is when the Spidey module is
required. Beware that if Spidey is used multiple times and you change some of
these on one usage, you are also changing default values for all subsequent
uses, unless they also override the same default option. However this is not a
serious problem since it is unlikely that Spidey will be C<use>d more than one
time and usually you only want to change LOG_CONF (the location of a Log4perl
configuration file): just do that for every use of Spidey if it is required
multiple times and you won't have to worry about the order all the use
functions are called.

=over 12

=item C<CACHE_DIR>

This is used for both debugging, cookie caching and result storage.

=item C<INLINE_DIR>

By default the _Inline directory gets made under the temporary directory,
e.g. usually C</tmp> on Unix.  If spiders are invoked from a CGI script and you
change this, it should be a place where your web server can write.  It is
better that this directory is used only by Spidey and the spiders you implement
with it.  See:
http://search.cpan.org/~ingy/Inline/Inline.pod#The_Inline_DIRECTORY

=item C<LOG_CONF>

Property file to adjust the logger configuration at runtime!  This path must be
absolute. A default system-wide file is supplied to <Log::Log4Perl> when not
overridden by the C<use>-level configuration option with the same name.  You
may want to copy and edit this file to a location where your script has write
access, in order to configure additional loggers, one for each spider you
develop.

=item C<LOG_DELAY>

Delay between logger configuration reloads.  Do not set too low to gain speed.

=item C<COOKIES>

Cookie file where a minimum of browser state is saved between different browser
execution.  Basically saving and retrieving cookies usually allows you to stay
logged in to a site, at lest until those cookies or a server-side session they
refer to does not expire.  Format is binary (Java serialized objects).

=item C<LOG>

Filename to use for all log files in the cache dir.

=back

Then there are browser-specific options and you can change their default values
for all browsers when use-ing the library. But they can also be changed on a
browser basis when creating a new browser with browser 'ini'.

=over 12

=item C<BROWSER>

Which browser to disguise as by default.  It makes the engine especially try to
emulate a certain browser quirks.  By default we set C<FIREFOX_3_6> because
generally C<INTERNET_EXPLORER_7> causes trouble even when emulated.  As a
matter of fact it may happen that when emulating a certain browser some
JavaScript code won't work while it will when emulating another browser.  So
this is a parameter you may want to experiment with when facing unsupported
JavaScript issues.  See:
http://htmlunit.sourceforge.net/apidocs/com/gargoylesoftware/htmlunit/BrowserVersion.html

=item C<CSS>

Unlike HtmlUnit CSS support is disabled by default to save on style sheet
downloads.  CSS selectors can still be used when this flag is off.

=item C<TIMEOUT>

HTTP timeout in milliseconds.  Don't set it too low otherwise requests will fail.  See:
http://htmlunit.sourceforge.net/apidocs/com/gargoylesoftware/htmlunit/WebClient.html#setTimeout(int)
The default value is just a hint.  There is no universal sensible timeout.  You
have to use your own best judgment based on your specific needs.

=item C<JS_FATAL>

Indicates whether a Java exception should be thrown when JavaScript execution
fails (the default in HtmlUnit) or it should be caught and just logged to allow
page execution to continue (the default in Spidey).

=item C<JS_TIMEOUT>

The default number of milliseconds that a JavaScript is allowed to execute
before being terminated.  A value of 0 or less means no timeout.  On production
machines it is recommended to set a non-zero value.  E.g. if you have an
infinite loop in some JavaScript code, HtmlUnit will interrupt the script after
it has run for such a time, avoiding it to eat up all your CPU time.  Do not
set too low or you'll get timeout errors.

=item C<SSL_CHECK>

SSL certificate checking.
http://htmlunit.sourceforge.net/apidocs/com/gargoylesoftware/htmlunit/WebClient.html#setUseInsecureSSL(boolean)

=back


=head2 EXPORT
 
The following functions are all exported by default, the only exception being
C<init>.  This documentation is meant to provide a rationale of Spidey features
and how they could be useful.  It should be read along tutorials, examples and
comments in the Spidey.pm source code.


=head3 init

Initialize the Spidey library.  Automatically executed when this module gets
included at runtime.  We do not need execution at compile time thus a C<BEGIN>
block has not been used.


=head3 logdie

Log and let die! This is not only useful as a macro but also uses
<Carp::longmess> to log the same detailed stack trace that confess prints.
Therefore always use logdie if you want to die on an error condition and log
some useful information as well.  Like built-in C<die> it never returns, but at
a certain stack level a possible code which uses the eval exception trap
mechanism can prevent the entire program to die.


=head3 browser

Subcommands:

=head4 ini or fin

Initializes and returns a new browser or finalizes an existent one.  Please see
the above section CONFIGURATION for options you can pass to ini.  fin only
takes the variable containing the browser to finalize.

=head4 ex

Selectively load web resources (e.g. external JavaScript files) to optimize.
Configuring this properly can speed up things considerably (e.g. avoid loading
JQuery if it is not needed to submit a form).

Pass a browser and a list of file patterns to skip.  They are partially matched
against full URLs to fetch (boundary matchers like ^ and $ are supported, of
course).

These are Java regex but the differences with Perl are small.  See:
http://download.oracle.com/javase/6/docs/api/java/util/regex/Pattern.html

Returns nothing.

=head4 go

Changes a browser address bar.  Takes a browser, a new URL and optionally a
list of parameters to C<sprintf> into it.

It is a wrapper around HtmlUnit C<getPage> that catches exceptions (e.g.
invalid syntax for addresses) and eases the building of URLs from differents
pieces: when more than two arguments are supplied the second one is taken as a
sprintf-like format string rather than a complete URL.  This is useful to
assemble URLs with parameters.  If all goes well returns the new page object.

=head4 js

A facility to turn JavaScript support on or off, in order to save resources and
speed up things.  Takes a browser and a state (either 0, 'on', 1 and 'off').
By default JavaScript is enabled.
  
Please note that enabling JavaScript after a page has been loaded has no effect
on that page, that is any possible script contained inside that page won't be
executed.  You must enable JavaScript before loading a dynamic page you want to
scrape with JavaScript support, where "loading" before using C<browser 'go'> or
clicking something that causes the current page to reload with C<node>.

Returns nothing.

=head4 cookies

Subcommands:

B<save>

Saves all HtmlUnit HTTP cookies pertaining to the browser specified as the only
argument to a file on disk.  In combination with the C<load> subcommand this
allows you to reuse a cookie cache between multiple execution of a spider,
although you are not "keeping your browser opened"  and you will have ini a new
browser and fetch the starting page again at each run.

I<About the file format used>: I was tempted to use the Netscape cookie file
format for easy inspection:

  http://www.cookiecentral.com/faq/#3.5
  http://www.netscape.com/newsref/std/cookie_spec.html

but it is an old file format that can't store all the information available in
the Set-Cookie2 headers, so you will probably lose some information if you save
in this format.  I do not want to run into subtle problems for nothing in the
world, thus I serialized the Java objects to make sure all the information is
preserved without any need to know how they are made inside :-P

Returns nothing.

B<load>

Loads a spider cookie cache.  The only parameter is a browser to load the
cookies into.  In other words it resumes the browser state.  Returns 1 (true)
if a cookie cache is available and has been correctly loaded.  0 (false)
otherwise.


=head3 date

Not for dating girls :)  Rather it is an integrated facility to parse a
date(-time) into the ISO format yyyy-mm-dd (hh:mm:ss).  Returns the converted
date or C<undef> if it cannot work it out.  For ambiguous cases one must tell
whether the format is American or not.  See:

  http://en.wikipedia.org/wiki/Date_and_time_notation_by_country

Takes a date string to convert and optionally two boolean named arguments:
C<monthfirst> for forcing interpretation of American date format and C<notime>
to get rid of the time (if any) and retain the date only.


=head3 form

Provides some utilities to tamper with forms.  These are either some tasks that
HtmlUnit makes incredibily difficult to perform mainly because of bad interface
design and excess of incapsulation (IMHO) or we just want to provide some
syntactic sugar.

=head4 hidden

Adds an hidden input to a form.  Sometimes useful to inject a parameter that it
is not part of the form, but it will be recognised by the server side script
the form is sent to.  It will temporary enable JavaScript due to HtmlUnit
restrictions, but restores the previous JavaScript state before returning.

The interface is akin to C<node>: it supports a couple of named params (C<by>
and C<match>) to locate the form to add the input to.  Another couple of params
(C<name> and C<value>) are obviously the INPUT tag name and value attribute
values.  You also need to fill C<browser> and C<page> because this command
needs to work with these objects.

Returns the modified page or the same page if failed.

=head4 sel

A command to handle drop-down menus.  It is a command with subcommands just
like in Tcl.  Subcommands:

B<desel>

Given a multiple drop-down list object unselect all options selected by
default, usually only one but not necessarily.  Does nothing if this is a
single-select box.

B<opt>

Given an HtmlSelect object as the 1st arg and one of the options allowed
values as the 2nd arg, selects just that option.  For multiple select boxes
where you have to select more than one option you have to pass an array of
option values as the 2nd arg.

B<setmul>

Turns a single select box into a multiple one.  E.g. needed if there is a
JavaScript which does that but you are browsing with JS disabled.


=head4 submit

Useful to submit a form with no submit button.  It will enable JavaScript due
to HtmlUnit restrictions.  Mandatory named parameters are: C<browser, page, by,
match>, the last two to locate the form of course.


=head3 node

A command with named parameters to get/set values or click HTML nodes,
typically elements, attributes or text.  A workhorse for filling in HTML
forms.  Note that click and set C<action>s may change the page they are made
on.  node returns the changed page.  It is up to the caller to get this return
value if the new page is needed.  This is usually the case with a click that
causes a new page to be loaded.

A C<page> option is mandatory like a C<value> one when the C<action> is C<set>.
By default node are located by C<id>.  Other methods to be specified into the
C<by> parameter are C<name>, C<tag>, C<xpath> and C<css> (for using CSS
selectors).

In order to make your spider code more consolidated by default this function
will croak - indeed C<confess> so debugging is easier :) - if it cannot locate
the node to handle.  If you prefer to handle this error by yourself or in the
few cases where it is not a serious error, set the C<caw> option to 0.  Then
you should probably check the return value to be false!

When locating a node by name or XPath, if more than one node is found, then
this method returns the first one.  If this is not the right one you wanted to
work with, maybe you have to be more specific in your selection.  Beware that
in HTML ID should be unique, but names may not.  If you really want to get more
than one, set the C<all> option to true and C<node> will return a list of nodes
matching.


=head3 sp

Gets the spider package name, i.e. the full name of the calling module or
C<'main'> if using Spidey from a main program. This is used to built a path
into the cache dir specific to your spider.
It does that by inspecting the call frame stack for you not to have to supply
this information.


=head3 table

Subcommands:

=head4 cell

Gets a cell at the specified row and column number (both 0-based) or a pointer
to an array of all cells in that row if no cell number is specified.

First argument can be either an HtmlUnit HtmlTable object or an HtmlTableRow,
previously obtained from table 'row'.
Returns either an HtmlTableCell or an array of those objects.

When trying to retrieve single cells out of table returns undef to signal the
error, but croaks if you try to get a row which doesn't exist.

=head4 debug

This command accepts a table and returns a plain HTML version of it with all
styles removed as a string.  In other words Given an HTML table it reformats it
making it easy to the human eye to see what indexes the relevant information
can be found.  That usually helps to write custom code for scraping information
from a table.

If you need to read a table by rows, there is a table header and you need to
give a sense to the data extracted and adapt to column-order changes or
additions, you may also find the command table 'read' below useful.

=head4 read

Reads a table by rows and converts it to another data structure, namely a hash
of hashes.  This method of scraping data from tables is very simple to code and
certainly better than making extraction depend highly on presentational
features.  After all a table has a definite structure so it's good to take
advantage of this.

But if a site happens to tag data structurally (alas, very few do this) it may
be better to do the extraction using DOM methods and/or Xpath expression to
locate fields based on their meaning and not their row or column position.
However HTML is structurally weak and even if single fields are tagged with
appropriate IDs, usually rows are not and you still have to depend on
formatting in order to locate them.

If you have to use the blind, numeric-index-based extraction method on a table,
it is recommended that you code some tests in your code to make sure that all
data are well-extracted.  They may ease debugging if something will change in
the future, e.g. a new field is added and/or some columns are swapped.

Anyway this method provides a bit of resilience: it reads the column headers to
find out what indexes you have to use.  This way your code will continue to
work even if column order changes or new columns are added.

You should usually provide some Perl code into the C<key> parameter. This is
evaluated internally to extract the ID of each table row. If you do not do that
(perhaps because there is not such a unique key in the data you are extracting)
an auto-increment value will be generated and used as an ID, starting from
zero.

Same goes for values: if you do not provide a C<value> parameter with some
custom code, cell values are always saved as they are found on site, otherwise
you can implement whatever handling you want. Usually values can be changed
later by looping over the resulting structure, but IDs are needed beforehand to
build the result hash.

Both code snippets are provided using Perl closures. As well as the C<table> to read,
other mandatory parameters are: a reference to the result hash C<out> and a C<map>
or hash that tells for each column header on site the respective key to use
into the resulting data structure (usually a shorter word).

Optional options are the number of C<header>s and C<footer> rows to skip (by
default respectively 1 and 0) and the row-number C<inc>rement (by default 1,
use 2 to extract only odd rows).

=head4 row

Gets a row at the given index as an HtmlTableRow object or a pointer to an
array of all rows if no index is specified.

Croaks when trying to get a nonexistent row, but not if the table is empty.


=head3 path

Concatenates one or more directory names and a filename to form a complete path
ending with a filename, relative to the C<$Conf{CACHE_DIR}>.


=head3 spath

Returns the full spider cache path. This is where cookies, log, slide and
result files are saved.  By convention the full package name of a spider is
lowercased for easy typing of such a path from the command line (e.g.
MySpiders::Google is mapped to the path myspiders/google/ in the cache).


=head3 file

Subcommands:

=head4 log

Given the spider package name, makes its cache dir and return the log file
name.  This is a facility used by the Log4perl configuration file.

=head4 path

Prefixes the spider cache path to any relative path and returns the absolute
path so obtained.

=head4 read

Just slurps in a file into a string from the spider cache.  Do not use with
large files.  E.g. it is used internally to slurp cookie files which is fine
because they are only a few kBs big.  Binary-safe.

=head4 slide

A facility to produce slides, for debugging purposes.  Calling syntax is clean
and if slide generation is disabled the overhead is negligible: just a pair of
fast function calls and nothing else done.

=head4 write

A facility to write out both HTML, text and binary files, for
debugging/logging/output purposes.  An undef text to write makes it to return a
still opened file handle that must be subsequently closed by the caller or Perl
will clean it up at the end of the program.  Use a relative path to the spider
cache path for the filename.  To be used to dump variables and full HTML pages,
e.g. it is used internally by C<file 'slide'> to build a slideshow of a spider
browsing.  Use C<'bin'> as first parameter for binary-safe writing.

=head4 type

Checks out the content type of a response.  Croaks if it is not one of the
expected file formats, given by a list of conventional extensions.  Otherwise
returns the extension corresponding to the file type detected, useful to
properly name the file.


=head3 mkdirp

Around 5 times faster than <File::Path>::mkpath when a long path already exists,
because it checks for the path existence with only one system call.


=head3 jserialize

Serializes a Java object.

Instead of writing arbitrary bytes, I chose to encode objects in base64, this
will turn any data into ascii safe text although base64 encoded data is larger
than the original data.  It also makes it easy to pass back data to Java when
deserializing because of Java strong-typed nature.  For consistency both
encoding and decoding is done in Java although perl has a module for that.
From the command line you can decode such a file using the base64(1) Linux
command along with the -d option.  What you get are binary data although if you
pipe it into strings(1) you will be able to see something, e.g. cookie names
and values, should you need to.

If you do not have base64(1) installed an alternative is:

  $ perl -MMIME::Base64 -e 'undef $/; print decode_base64 <>'
        cookies.base64 |less

=head3 junserialize

Unserializes a Java object saved to disk in portable Base64 encoding schema.
Returns a generic C<java.lang.Object> that must be casted to the effective type
before use.

=head3 pages

A simple algorithm to browse through a multiple-page result set. Of course you
must provide a method to detect if there is a next page and follow the link to
it and some code to extract each page data, e.g. by using C<table 'read'> if
data are formatted into a table with a header or whatever code it is
appropriate.

=head1 AUTHOR
 
Antonio Bonifati <ninuzzo@cpan.org> - http://go.to/ninuzzo
 
=head1 BUGS

Please report any bugs or feature requests to C<bug-www-htmlunit-spidey at
rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=WWW-HtmlUnit-Spidey>.  I will
be notified, and then you'll automatically be notified of progress on your bug
as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc WWW::HtmlUnit::Spidey

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WWW-HtmlUnit-Spidey>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/WWW-HtmlUnit-Spidey>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/WWW-HtmlUnit-Spidey>

=item * Search CPAN

L<http://search.cpan.org/dist/WWW-HtmlUnit-Spidey/>

=back

=head1 SEE ALSO

<WWW::HtmlUnit>, L<http://htmlunit.sourceforge.net>

=head1 COPYRIGHT

   Copyright 2011 Antonio Bonifati

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

=cut
