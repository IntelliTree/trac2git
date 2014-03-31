#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use Try::Tiny;

$|= 1;

my $repo= shift @ARGV // '';
$repo =~ m:^\w+/\w+$:
	or die "repo argument should be 'username/reponame' format";

my $token= slurp('auth-token');
chomp $token;
print STDERR "loaded token\n";

my $issues_json= slurp('issues.json');
my $issues= decode_json($issues_json);
print STDERR "loaded issues\n";

my $base_uri= 'https://api.github.com/repos/$repo';
my $a= LWP::UserAgent->new(
	agent => 'silverdirk',
	from => 'mike@ndvana.net',
	default_headers => HTTP::Headers->new(
		'Authorization' => "token $token",
	),
	protocols_allowed => [ 'HTTPS' ],
	keep_alive => 3,
);

my %labels= map { $_ => 1 } github_get_labels();
print STDERR "fetched set of labels\n";

github_create_issue($_) for @$issues;

sub slurp {
	my $name= shift;
	open my $f, "<$name" or die "Can't open $name: $!";
	local $/= undef;
	return scalar <$f>;
}

sub github_get_labels {
	my $data= github_api(get => 'labels');
	return map { $_->{name} } @$data;
}

sub github_create_label {
	my $name= shift;
	my $data= github_api(post => "labels", { name => $name });
	$data->{name} eq $name or die "name mismatch?";
	$labels{$name}= 1;
}

sub github_create_issue {
	my $issue= shift;
	my %issue= %$issue;
	if (try { github_api(get => "issues/$issue->{number}"); 1; }) {
		print STDERR "Issue $issue->{number} exists already\n";
		return;
	}
	my $comments= (delete $issue{comments}) || [];
	for (@{ $issue{labels} || [] }) {
		defined $labels{$_} or github_create_label($_);
	}
	my $res_issue= github_api(post => 'issues', \%issue);
	for (@$comments) {
		github_create_issue_comment( $res_issue->{number}, $_ );
	}
	if ($issue{state} ne $res_issue->{state}) {
		$res_issue= github_api(post => "issues/$res_issue->{number}", \%issue);
	}
	$res_issue;
}

sub github_create_issue_comment {
	my ($issue_num, $comment)= @_;
	return github_api(post => "issues/$issue_num/comments", $comment);
}

sub github_api {
	my ($method, $path, $data)= @_;
	my $json= $data? encode_json($data) : {};
	my $res= $a->$method("$base_uri/$path",
		defined $data? ( 'Content-Type' => 'application/json', Content => encode_json($data) ) : ()
	);
	$res->is_success or die "$method $path: ".$res->status_line." ".$res->decoded_content;
	my $res_data= decode_json($res->decoded_content);
	return $res_data;
}