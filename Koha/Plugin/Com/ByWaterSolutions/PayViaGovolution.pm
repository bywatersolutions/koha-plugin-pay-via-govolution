package Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth qw(get_template_and_user);
use Koha::Account;
use Koha::Account::Lines;
use List::Util qw(sum);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(gettimeofday);
use JSON qw(decode_json);

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name          => 'Pay Via Govolution',
    author        => 'Nick Clemens',
    description   => 'This plugin enables online OPAC fee payments via Govolution',
    date_authored => '2023-05-30',
    date_updated  => '1900-01-01',
    minimum_version => '22.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

our $ENABLE_DEBUGGING = 1;

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my @accountline_ids = $cgi->multi_param('accountline');

    my $rs = Koha::Database->new()->schema()->resultset('Accountline');
    my @accountlines = map { $rs->find($_) } @accountline_ids;

    my $patron = scalar Koha::Patrons->find($borrowernumber);

    my $amount = sprintf("%.2f", sum( map { $_->amountoutstanding } @accountlines ) );

    # Govolution will take our form info, and then send a 'session verification request'
    # with a 'remittance_id' We need to store all transaction data to look it up and return
    # a 'session verification response' 
    my $remittance_id = "B" . $borrowernumber . "T" . time;
    my $application_id = $self->retrieve_data('application_id');
    C4::Context->dbh->do(
        q{
        INSERT INTO govolution_plugin_tokens ( token, borrowernumber, accountline_ids, amount, application_id )
        VALUES ( ?, ?, ?, ?, ? )
    }, undef, $remittance_id, $borrowernumber, join('|',@accountline_ids), $amount, $application_id
    );

    $template->param(
        borrower             => $patron,
        remittance_id        => $remittance_id,
        accountlines         => \@accountlines,
        url                  => $self->retrieve_data('url'),
        application_id       => $application_id
    );

    print $cgi->header();
    print $template->output();
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $success = $cgi->param('success');
    my $fail = $cgi->param('fail');


    $template->param(
        borrower  => scalar Koha::Patrons->find($borrowernumber),
        success    => $success,
        fail       => $fail,
    );

    print $cgi->header();
    print $template->output();
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            application_id => $self->retrieve_data('application_id'),
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            url => $self->retrieve_data('url'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                application_id => $cgi->param('application_id'),
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                url            => $cgi->param('url'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    my $dbh = C4::Context->dbh();

    my $query = q{
		CREATE TABLE IF NOT EXISTS govolution_plugin_tokens
		  (
			 token          VARCHAR(128),
			 created_on     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			 borrowernumber INT(11) NOT NULL,
             accountline_ids VARCHAR(255) NOT NULL,
             amount         DECIMAL(28,6),
             application_id VARCHAR(255),
             security_id    VARCHAR(255) NULL DEFAULT NULL,
			 PRIMARY KEY (token),
			 CONSTRAINT token_bn FOREIGN KEY (borrowernumber) REFERENCES borrowers (
			 borrowernumber ) ON DELETE CASCADE ON UPDATE CASCADE
		  )
		ENGINE=innodb
		DEFAULT charset=utf8mb4
		COLLATE=utf8mb4_unicode_ci;
    };

    return $dbh->do( $query );

}

sub uninstall() {
    return 1;
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str); 

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'govolution';
}

1;
