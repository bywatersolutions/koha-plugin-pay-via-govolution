package Koha::Plugin::Com::ByWaterSolutions::PayViaGovolution::Controller;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use JSON;
use WWW::Form::UrlEncoded qw(parse_urlencoded);

our $ENABLE_DEBUGGING = 0;

sub verification {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn Data::Dumper::Dumper( "PARAMS", $params );

    my $application_id = $params->{application_id};
    my $message_version = $params->{message_version};
    my $remittance_id = $params->{remittance_id};
    my $security_id = $params->{security_id};

    my $dbh = C4::Context->dbh;
    my $query = "SELECT * FROM govolution_plugin_tokens WHERE token = ?";
    my $remittance_hr = $dbh->selectrow_hashref( $query, undef, $remittance_id);

    warn Data::Dumper::Dumper( "TOKEN ROW",$remittance_hr );

    return $c->render(
        status  => 500,
        openapi => {
            continue_processing => JSON::false,
            echo_failure => JSON::true,
            user_message => "This transaction cannot be found"
        }
    ) unless $remittance_hr;

    my $update_query = "UPDATE govolution_plugin_tokens SET security_id = ? WHERE token = ?";
    $dbh->do($update_query, undef, ($security_id, $remittance_id) );

    return $c->render(
        status => 200,
        openapi => {
            action_type => "PayNow",
            continue_processing => JSON::true,
            language => 'en_US',
            amount => $remittance_hr->{amount},
        }
    );

}
    
sub notification {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn Data::Dumper::Dumper( "PARAMS", $params );

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

    unless( $remittance_hr && $security_id eq $remittance_hr->{security_id} ){
        return $c->render(
            status  => 500,
            openapi => {
                success => JSON::false,
                user_message => "This transaction could not be found"
            }
        );
    }


    warn Data::Dumper::Dumper( "TOKEN ROW",$remittance_hr );
    my $borrowernumber = $remittance_hr->{borrowernumber};
    my $remittance_accountline_ids = $remittance_hr->{accountline_ids};
    my @accountline_ids = split('|',$remittance_accountline_ids);
    my $remittance_amount = $remittance_hr->{amount};

    if( $remittance_amount != $amount ){
        warn "rejected";
        return $c->render(
            status  => 500,
            openapi => {
                success => JSON::false,
                user_message => "This transaction amount did not match the amount expected"
            }
        );
    }

    my $patron = Koha::Patrons->find( $borrowernumber );
    my $account = $patron->account;
    my @account_lines = Koha::Account::Lines->search({
        accountlines_id => { -in => \@accountline_ids }
    })->as_list;
    eval{
        warn "apyng";
        $account->pay(
            {
                amount => $amount,
                lines  => \@account_lines,
                note   => "Govolution transaction $transaction_id",
                library_id => $patron->branchcode
            }
        );
        warn "payed";
    };
    unless( $@ ){
        $dbh->do("DELETE from govolution_plugin_tokens WHERE token = ?", undef, $remittance_id);
        warn "return ok";
        return $c->render(
            status => 200,
            openapi => {
                success => JSON::true,
            }
        );
    } else {
        warn "return nok";
        return $c->render(
            status  => 500,
            openapi => {
                success => JSON::false,
                user_message => "There was an error processing this payment: $@"
            }
        );
    }

}

1;
