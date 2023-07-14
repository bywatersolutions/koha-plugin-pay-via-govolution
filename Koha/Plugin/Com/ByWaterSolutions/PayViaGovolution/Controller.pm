package Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution::Controller;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

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

    my $dbh = C4::Context->dbh;
    my $query = "SELECT * FROM govolution_plugin_tokens WHERE token = ? AND created_on >= DATE_SUB(NOW(), INTERVAL 5 MINUTE)";
    my $remittance_hr = $dbh->selectrow_hashref( $query, undef, $remittance_id);

    return $c->render(
        status  => 500,
        text => q{continue_processing=false&echo_failure=true&user_message="This transaction cannot be found"}
    ) unless $remittance_hr && $application_id eq $remittance_hr->{application_id};

    my $update_query = "UPDATE govolution_plugin_tokens SET security_id = ? WHERE token = ?";
    $dbh->do($update_query, undef, ($security_id, $remittance_id) );

    return $c->render(
        status => 200,
        text => qw{action_type=PayNow&continue_processing=true&language=en_US&amount=} . $remittance_hr->{amount}
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
    my $query = "SELECT * FROM govolution_plugin_tokens WHERE token = ?";
    my $remittance_hr = $dbh->selectrow_hashref( $query, undef, $remittance_id);

    unless( defined $remittance_hr && $security_id eq $remittance_hr->{security_id} && $application_id eq $remittance_hr->{application_id} ){
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
    my @accountline_ids = split('|',$remittance_accountline_ids);
    my $remittance_amount = $remittance_hr->{amount};

    if( $remittance_amount != $amount ){
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
        $dbh->do("DELETE from govolution_plugin_tokens WHERE token = ?", undef, $remittance_id);
        return $c->render(
            status => 200,
            text => q{success=true}
        );
    } else {
        return $c->render(
            status  => 500,
            text => q{success=false&user_message="There was an error processing this payment: } .$@ .q{"}
        );
    }

}

1;
