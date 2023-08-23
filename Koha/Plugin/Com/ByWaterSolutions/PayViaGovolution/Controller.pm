package Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution::Controller;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution;
use JSON;
use WWW::Form::UrlEncoded qw(parse_urlencoded);

our $ENABLE_DEBUGGING = 0;

sub verification {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;

    my $application_id = $params->{application_id};
    my $message_version = $params->{message_version};
    my $remittance_id = $params->{remittance_id};
    my $security_id = $params->{security_id};

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution->new();
    my $table = $plugin->get_qualified_table_name('tokens');
    my $debug = $plugin->retrieve_data('debug');
    my $dbh = C4::Context->dbh;
    my $query = "SELECT * FROM $table WHERE token = ? AND created_on >= DATE_SUB(NOW(), INTERVAL 5 MINUTE)";
    my $remittance_hr = $dbh->selectrow_hashref( $query, undef, $remittance_id);

    warn "Received app id: $application_id version $message_version remit id $remittance_id sec id $security_id" if $debug;
    return $c->render(
        status  => 500,
        text => q{continue_processing=false&echo_failure=true&user_message="This transaction cannot be found"}
    ) unless $remittance_hr && $application_id eq $remittance_hr->{application_id};

    my $update_query = "UPDATE $table SET security_id = ? WHERE token = ?";
    $dbh->do($update_query, undef, ($security_id, $remittance_id) );

    my $text = qw{action_type=PayNow&continue_processing=true&language=en_US&amount=} . $remittance_hr->{amount};
    $text .= qw{&parcel=} . $remittance_hr->{parcel};

    warn "Sent content: $text" if $debug;

    return $c->render(
        status => 200,
        text => $text,
    );

}
    
sub notification {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;

    my $application_id = $params->{application_id};
    my $message_version = $params->{message_version};
    my $remittance_id = $params->{remittance_id};
    my $security_id = $params->{security_id};
    my $transaction_status = $params->{transaction_status};
    my $payment_type = $params->{payment_type};
    my $amount = $params->{amount};
    my $transaction_id = $params->{transaction_id};

    my $dbh = C4::Context->dbh;
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution->new();
    my $table = $plugin->get_qualified_table_name('tokens');
    my $debug = $plugin->retrieve_data('debug');

    warn "Received app id: $application_id version $message_version remit id $remittance_id sec id $security_id" if $debug;
    warn "Received status: $transaction_status type $payment_type aount $amount transaction id $transaction_id" if $debug;

    my $query = "SELECT * FROM $table WHERE token = ?";
    my $remittance_hr = $dbh->selectrow_hashref( $query, undef, $remittance_id);

    unless( defined $remittance_hr && $security_id eq $remittance_hr->{security_id} && $application_id eq $remittance_hr->{application_id} ){
        warn "GoVolution: Could not find transaction with remittance id $remittance_id" if $debug;
        return $c->render(
            status  => 500,
            text => q{success=false&user_message="This transaction could not be found"}
        );
    }

    unless( $transaction_status == 0 ){
        return $c->render(
            status  => 500,
            text => q{success=false&user_message="This transaction failed on the remote end"}
        );
    }

    my $borrowernumber = $remittance_hr->{borrowernumber};
    my $remittance_accountline_ids = $remittance_hr->{accountline_ids};
    my @accountline_ids = split('\|',$remittance_accountline_ids);
    my $remittance_amount = $remittance_hr->{amount};

    if( $remittance_amount != $amount ){
        warn "GoVolution: Amounts did not match for remittance id $remittance_id" if $debug;
        return $c->render(
            status  => 500,
            text => q{success=false&user_message="This transaction amount did not match the amount expected"}
        );
    }

    my $patron = Koha::Patrons->find( $borrowernumber );
    my $account = $patron->account;
    my @account_lines = Koha::Account::Lines->search({
        accountlines_id => { -in => \@accountline_ids }
    })->as_list;
    eval{
        $account->pay(
            {
                amount => $amount,
                lines  => \@account_lines,
                note   => "Govolution transaction $transaction_id (application id: $application_id) ",
                library_id => $patron->branchcode
            }
        );
    };
    unless( $@ ){
        $dbh->do("DELETE from $table WHERE token = ?", undef, $remittance_id);
        warn "GoVolution: Payment succeeded with remittance id $remittance_id" if $debug;
        return $c->render(
            status => 200,
            text => q{success=true}
        );
    } else {
        warn "GoVolution: Payment failed with remittance id $remittance_id, error: $@" if $debug;
        return $c->render(
            status  => 500,
            text => q{success=false&user_message="There was an error processing this payment: } .$@ .q{"}
        );
    }

}

1;
