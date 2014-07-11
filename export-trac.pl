#! /usr/bin/perl
use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use JSON;
use DateTime;
use Carp;
package DateTime;
sub TO_JSON { my $d= shift; $d.'Z' }
package main;
my $anonymize= 0;

my $fname= shift @ARGV;
my $d= DBI->connect("dbi:SQLite:$fname", '', '', {RaiseError=>1, AutoCommit=>1}) or die;

my $user_map_json= slurp('user_map.json');
my %users= %{ JSON->new->relaxed->decode($user_map_json) };
my @issues= map { ticket_to_issue($_) } @{ load_trac_tickets() };

#use DDP;
#use DDP filters => {
#	'DateTime' => sub { my $date= ''.shift; p $date; },
#};
#p $issues[245];
print JSON->new->ascii->allow_blessed->convert_blessed->encode(\@issues)."\n";

sub slurp {
	my $name= shift;
	open my $f, "<$name" or die "Can't open $name: $!";
	local $/= undef;
	return scalar <$f>;
}

sub load_trac_tickets {
	my $tickets= $d->selectall_arrayref('select * from ticket order by id', { Slice => {} });
	for (@$tickets) {
		$_->{changes}= $d->selectall_arrayref(
			'select * from ticket_change where ticket = ? order by time', { Slice => {} },
			$_->{id});
	}
	return $tickets;
}

sub trac_time_to_utc {
	DateTime->from_epoch(epoch => int($_[0]/1000000), time_zone => 'UTC');
}

sub remap_user {
	$users{$_[0]} // confess "Unknown user $_[0] (".join(',',caller).')';
}

sub ticket_to_issue {
	my $t= shift;
	my $issue= {
		number     => $t->{id},
		title      => $t->{summary},
		body       => wiki_to_md( $t->{description} ),
		assignee   => remap_user( $t->{owner} ),
		user       => remap_user( $t->{reporter} ),
		created_at => trac_time_to_utc($t->{time}),
		updated_at => trac_time_to_utc($t->{changetime}),
		state      => 'open',
		closed_at  => undef,
		closed_by  => undef,
		labels     => [
			grep { defined && length } map { $t->{$_} } qw: type priority resolution :
		],
		comments   => [],
	};
	$issue->{body}= "(no text)"
		unless defined $issue->{body} and length $issue->{body};
	my %changes;
	my $closed_at= 0;
	my $closed_by= undef;
	for (@{ $t->{changes} }) {
		# Sort changes by date and author
		$changes{$_->{time}}{$_->{author}}{$_->{field}}=
			[ $_->{oldvalue}, $_->{newvalue} ]
			unless $_->{field} =~ /^_/;
		# Find the last change of "status" to "closed"
		if ($_->{field} =~ /^status$/i) {
			if ($_->{time} > $closed_at) {
				if ($_->{newvalue} =~ /^closed$/) {
					$closed_at= $_->{time};
					$closed_by= $_->{author};
				} else {
					$closed_at= 0;
					$closed_by= undef;
				}
			}
		}
	}
	# If the last change of state was 'closed', update the issue fields with the details
	if ($closed_at) {
		$issue->{closed_at}= trac_time_to_utc($closed_at);
		$issue->{closed_by}= remap_user( $closed_by );
		$issue->{state}= 'closed';
	}
	# Now build change messages for each batch of changes
	for my $time (sort keys %changes) {
		for my $author (sort keys %{$changes{$time}}) {
			push @{$issue->{comments}},
				changes_to_comment($t->{id}, $time, $author, $changes{$time}{$author});
		}
	}
	$issue->{title} =~ s/[a-z]/i/gi if $anonymize;
	return $issue;
}

sub changes_to_comment {
	my ($ticket, $time, $author, $changes)= @_;

	# Ignore the trac ticket comments, since GitHub should add these automatically
	if (defined $changes->{comment}[1] && $changes->{comment}[1] =~ /CommitTicketReference/) {
		return ();
	}

	my $num= $changes->{comment}[0];
	defined $num and length $num
		or die "ticket $ticket has un-numbered comment for $time/$author\n";

	my $date= trac_time_to_utc($time)->set_time_zone('local');
	my $date_str= $date->ymd . ' ' . $date->hms;
	my $comment= '';#"#### update $num on $date_str by $author ####\n\n";
	for (grep { $_ ne 'comment' && $_ ne 'description' } keys %$changes) {
		my ($old, $new)= @{ $changes->{$_} };
		$old= defined $old && length $old? $old : undef;
		$new= defined $new && length $new? $new : undef;
		my $old_md= md_esc($old) if defined $old;
		my $new_md= md_esc($new) if defined $new;
		$comment .= (defined $old && defined $new)?
			"  * **${_}** changed from *${old_md}* to *${new_md}*\n"
			: defined $old? "  * **${_}** *${old_md}* deleted\n"
			: defined $new? "  * **${_}** set to *${new_md}*\n"
			: '';
	}
	if (defined $changes->{description}) {
		$comment .= "  * **description** changed, old value was:\n"
			. wiki_to_md( $changes->{description}[0] );
		$comment .= "\n" unless substr($comment, -1) eq "\n";
	}
	if (defined $changes->{comment}[1]) {
		$comment .= "\n".wiki_to_md($changes->{comment}[1]);
	}
	
	$comment =~ s/[a-z]/i/gi if $anonymize;
	
	$comment = '(no text)'
		unless $comment =~ /\S/;
	return {
		user       => remap_user($author),
		created_at => trac_time_to_utc($time),
		body       => $comment
	};
}

sub md_esc {
	my $x= shift;
	$x =~ s/([-{}\[\]()_*`\\#+.!])/\\$1/g;
	return $x;
}

sub wiki_to_md {
	my $x= shift;
	# normalize newlines
	$x =~ s/\r\n/\n/sg;
	# Convert code block notation
	no warnings 'uninitialized';
	$x =~ s/\{{3}(?:\s*#!(\w+))?/```$1/g;
	$x =~ s/\}{3}/```/g;
	# anonymize option, for testing on public repos
	$x =~ s/[a-z]/i/gi if $anonymize;
	return $x;
}
