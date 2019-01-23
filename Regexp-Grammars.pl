#!/usr/bin/env perl
use 5.024;
use Capture::Tiny qw(capture);
use File::Slurper qw(read_binary write_binary);
use Marpa::R2 qw();
use Moops;
use Kavorka qw(fun);
use Test::More import => [qw(diag done_testing)];
use Test::Deep qw(cmp_set);
use Tie::Hash::Indexed qw();

class Metagrammar {
    method parse(Str :$input) {
        my $r = Marpa::R2::Scanless::R->new({
            grammar => Marpa::R2::Scanless::G->new({
                bless_package => 'Metagrammar',
                source => \<<~'',
                    :default ::= action => [values] bless => ::lhs
                    lexeme default = action => [values] latm => 1 bless => ::name
                    :discard ~ whitespace
                    whitespace ~ [\s]+
                    Grammar ::= Rule+
                    Rule ::= Nonterminal Equal Symplus
                    Symplus ::= Sym+
                    Sym ::= Nonterminal | Terminal
                    Nonterminal ~ [A-Za-z]+
                    Terminal ~ [\x{27}] Unquote [\x{27}] | 'ε'
                    Unquote ~ [^']+ #'
                    Equal ~ '⩴' | '→'

            })
        });
        $r->read(\$input);
        return $r->value->$*;
    }
    method Equal(@values) {}
    method Grammar(@values) {
        my @r = map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        my $start = $r[0][0]->$*;
        tie my %r, 'Tie::Hash::Indexed';
        for my $r (@r) {
            my $name = $r->[0]->$*;
            push $r{$name}->@*, $r->[1];
        }
        my $ret;
        for my $k (keys %r) {
            $ret .= "<rule: $k>\n";
            my @syms;
            for my $syms ($r{$k}->@*) {
                my $p = "\t" . join ' ', map {
                    if ('' eq $_) {
                        ''
                    } elsif ($_->isa('Nonterminal')) {
                        sprintf '<[anon=%s]>', $_->$*
                    } elsif ($_->isa('Terminal')) {
                        sprintf '<[anon=(%s)]>', quotemeta($_->$*)
                    } else {
                        die;
                    }
                } $syms->@*;
                $p .= sprintf "\n\t<MATCH=(?{['%s', \$MATCH{anon} ? \$MATCH{anon}->\@* : undef]})>\n", $k;
                push @syms, $p;
            }
            $ret .= join "  |\n", @syms;
        };
        return($ret, $start);
    }
    method Nonterminal(@values) {
        return bless \$values[0], 'Nonterminal';
    }
    method Rule(@values) {
        my @r = map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        return \@r;
    }
    method Sym(@values) {
        my $r = [map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values]->[0];
    }
    method Symplus(@values) {
        my $r = [map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values];
    }
    method Terminal(@values) {
        return '' if 'ε' eq $values[0];
        $values[0] =~ s/^'//;
        $values[0] =~ s/'$//;
        $values[0] =~ s/\\x([0-9]+)/chr hex $1/eg;
        return bless \$values[0], 'Terminal';
    }
}

fun visit($v) {
    my $r = { values => [], type => ref($v) =~ s/^Metagrammar:://r };
    push $r->{values}->@*, map { ref($_) ? visit($_) : $_ } $v->@*;
    return $r;
}

fun MAIN(Str $grammar_name) {
    my $grammar = read_binary "grammars/$grammar_name";
    my $v = visit(Metagrammar->new->parse(input => $grammar));
    my ($generated, $start) = Metagrammar->can($v->{type})->($v->{type}, $v->{values}->@*);
    mkdir 'generated';
    my $template = <<~"...";
        use Regexp::Grammars;
        use JSON::MaybeXS qw(encode_json);
        print encode_json \$/{$start} if (do { local \$/; readline; }) =~ qr{
        <nocontext:>
        <$start>
        __GRAMMAR__
        }msx;
        ...

    write_binary(
        "generated/${grammar_name}__Regexp-Grammars.pl",
        $template =~ s/__GRAMMAR__/$generated/r
    );
    my @input = split /\n/, read_binary "input/$grammar_name";
    my @output = split /\n/, read_binary "output/$grammar_name";
    while (my ($idx, $input) = each @input) {
        my $status;
        my ($out, $err) = capture {
            open my $proc, '|-', $^X, "generated/${grammar_name}__Regexp-Grammars.pl";
            $proc->print($input);
            close $proc;
            $status = $?;
        };
        cmp_set(
            [split '␞', $out],
            [split '␞', $output[$idx]],
            "${grammar_name}__Regexp-Grammars.pl $input"
        ) or diag $err;
    }
    done_testing;
}

die "usage: $0 grammar_name\n" unless $ARGV[0];
MAIN($ARGV[0] =~ s|^grammars/||r);
