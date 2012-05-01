#!/usr/bin/perl
# Copyright © 2011 Jason J.A. Stephenson <jason@sigio.com>
#
# This file is part of issa.
#
# issa is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# issa is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
# License for more details.
#
# You should have received a copy of the GNU General Public License
# along with issa.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use XML::XPath;
use OpenSRF::System;
use OpenSRF::Utils::SettingsClient;
use Digest::MD5 qw/md5_hex/;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Const qw/:const/;
use Scalar::Util qw(reftype blessed);
use MARC::Record;
use MARC::Field;
use MARC::File::XML;
use POSIX qw/strftime/;
use DateTime;

# Hash to configure the prompts used by this program. Each named entry
# points to an array with the following members:
# 0 - The prompt string to display.
# 1 - A regex pattern to validate the prompt.
# 2 - A message to display when the input fails validation.
my %prompts = (
    'main' => [ 'Enter Choice [1-7,Q]>', '^[1-7qQ]$', 'Please enter a single digit from 1 to 6 or a single letter Q.' ],
    'patron' => [ 'Enter patron barcode>', '.+', '' ],
    'copy' => [ 'Enter copy barcode>', '.+', '' ],
    'hold' => [ 'Enter Choice [1-2]>', '^[12qQ]$', 'Please enter a single digit from 1 to 2 or a single letter Q.' ],
    'bib' => [ 'Enter bibliographic id>', '^(?:\d+|[qQ])$', 'Please enter a string of digits or a single letter Q.' ],
    'title' => [ 'Enter title>', '.+', '' ],
    'callnumber' => [ 'Enter call number>', '.+', '' ],
    'pickup' => [ 'Enter pickup library>', '.+', '' ],
);

my $config_file = '/openils/conf/issa.xml';
$config_file = $ARGV[1] if (defined($ARGV[0]) && $ARGV[0] eq "-config");

# Load our configuration
my $xpath = XML::XPath->new(filename => $config_file);
my $bootstrap = $xpath->findvalue("/issa/bootstrap_config")->value();
my $username = $xpath->findvalue("/issa/credentials/username")->value();
my $password = $xpath->findvalue("/issa/credentials/password")->value();
my $work_ou = $xpath->findvalue("/issa/credentials/work_ou")->value();
my $workstation = $xpath->findvalue("/issa/credentials/workstation")->value();
my $bre_source = $xpath->findvalue("/issa/config_bib_source")->value();
my $timeout = $xpath->findvalue("/issa/timeout")->value();

# Parameters for title holds:
my $title_holds = {};
$title_holds->{unit} = $xpath->findvalue('/issa/holds/title/duration/@unit')->value();
$title_holds->{duration} = $xpath->findvalue('/issa/holds/title/duration')->value();

# Block types to block patrons:
my $block_types = [];
my $bnodes = $xpath->find('/issa/patrons/block_on/@block');
if ($bnodes) {
    if ($bnodes->isa('XML::XPath::NodeSet')) {
        foreach ($bnodes->get_nodelist) {
            push(@{$block_types}, $_->getData) if ($_->isa('XML::XPath::Node::Attribute'));
        }
    } elsif ($bnodes->isa('XML::XPath::Node::Attribute')) {
        push(@{$block_types}, $bnodes->getData);
    }
}

# Setup our SIGALRM handler.
$SIG{'ALRM'} = \&logout;

# Get our local timezone for setting hold expiration dates.
my $tz = DateTime::TimeZone->new(name => 'local');

# Make sure that the work_ou shortname is prepended to the workstation
# name.
$workstation = $work_ou . '-' . $workstation if ($workstation !~ /^${work_ou}-/);

customize_prompts();

# Bootstrap the client
OpenSRF::System->bootstrap_client(config_file => $bootstrap);
my $idl = OpenSRF::Utils::SettingsClient->new->config_value("IDL");
Fieldmapper->import(IDL => $idl);

# Initialize CStoreEditor:
OpenILS::Utils::CStoreEditor->init;

my %session = login($username, $password, $workstation);

if (defined($session{authtoken})) {
    my $input = "";
    my $ou = org_unit_from_shortname($work_ou);
    if (!blessed($ou)) {
        die("Misconfiguration encountered.\nPlease inform support that $work_ou org_unit does not exist.");
    }
    while (lc($input) ne 'q') {
        print_main_menu();
        $input = prompt('main');

        if ($input eq '1') {
            my $p = prompt('patron');
            next if ($p =~ /^[qQ]$/);

            print("\n");

            my $pid = user_id_from_barcode($p);
            if (!defined($pid) || (ref($pid) && reftype($pid) eq 'HASH')) {
                print("PATRON_NOT_FOUND\n\n");
                next;
            }

            my $patron = flesh_user($pid);
            if (blessed($patron)) {
                if ($patron->deleted eq 't') {
                    print("PATRON_DELETED\n\n");
                    next;
                }
                printf("Name: %s %s%s\n", $patron->first_given_name, defined($patron->second_given_name) ? $patron->second_given_name . " " : "", $patron->family_name);
                printf("Email: %s\n", defined($patron->email) ? $patron->email : "N/A");
                printf("Home Library: %s (%s)\n", $patron->home_ou->name, $patron->home_ou->shortname);
                print("Active Cards:");
                printf(" %s", $patron->card->barcode) if ($patron->card && $patron->card->active eq 't');
                my $card;
                foreach $card (@{$patron->cards}) {
                    next if ($card->id eq $patron->card->id);
                    printf(" %s", $card->barcode) if ($card->active eq 't');
                }
                print("\n");
                printf("Expiration Date: %s\n", defined($patron->expire_date) ? $patron->expire_date : "N/A");
                print("Status:");
                my $patron_ok = 1;
                my @penalties = @{$patron->standing_penalties};
                if ($patron->barred eq 't') {
                    print(" Barred\n");
                    $patron_ok = 0;
                } elsif ($patron->active eq 'f') {
                    print(" Inactive\n");
                    $patron_ok = 0;
                } elsif ($#penalties > -1) {
                    my $penalty;
                    foreach $penalty (@penalties) {
                        if (defined($penalty->standing_penalty->block_list)) {
                            my @block_list = split(/\|/, $penalty->standing_penalty->block_list);
                            foreach my $block (@block_list) {
                                foreach my $block_on (@$block_types) {
                                    if ($block eq $block_on) {
                                        printf(" %s", $penalty->standing_penalty->name);
                                        $patron_ok = 0;
                                    }
                                    last unless ($patron_ok);
                                }
                                last unless ($patron_ok);
                            }
                        }
                    }
                    print("\n") unless ($patron_ok);
                } elsif ($patron->juvenile eq 't') {
                    print(" Juvenile\n");
                    # We lie, just to keep Active from also printing.
                    $patron_ok = 0;
                }
                if ($patron_ok) {
                    print(" Active\n");
                }
                print("\n");
            } else {
                print("PATRON_NOT_FOUND\n\n");
                next;
            }

        } elsif ($input eq '2') {
            my $c = prompt('copy');
            next if ($c =~ /^[qQ]$/);

            print("\n");

            my $r = bre_from_barcode($c);
            if (!defined($r)) {
                print("COPY_BARCODE_NOT_FOUND\n\n");
                next;
            } elsif (blessed($r)) {
                printf("%d\n\n", $r->id);
            } elsif (ref($r) && reftype($r) eq 'HASH') {
                printf("%s\n\n", $r->{textcode});
            }

        } elsif ($input eq '3') {
            print_hold_identifier_menu();
            my $which = prompt('hold');
            next if ($which =~ /^[qQ]$/);

            my $bib = 0;
            my $copy = 0;

            if ($which eq '1') {
                $bib = prompt('bib');
                next if ($bib =~ /^[qQ]$/);
            } else {
                my $c = prompt('copy');
                next if ($c =~ /^[qQ]$/);
                $copy = copy_from_barcode($c);
                if (!blessed($copy) && ref($copy) && reftype($copy) eq 'HASH') {
                    printf("\n%s\n\n", $copy->{textcode});
                    next;
                }
            }

            my $pcode = prompt('patron');
            next if ($pcode =~ /^[qQ]$/);

            my $pid = user_id_from_barcode($pcode);
            if (!defined($pid) || (ref($pid) && reftype($pid) eq 'HASH')) {
                print("\nPATRON_NOT_FOUND\n\n");
                next;
            }
            my $patron = flesh_user($pid);

            my $pickup = prompt('pickup');
            next if ($pickup =~ /^[qQ]$/);

            $pickup = org_unit_from_shortname($pickup);
            if (ref($pickup) eq 'HASH') {
                printf("\n%s\n\n", $pickup->{textcode});
                next;
            } elsif (!can_have_users($pickup)) {
                print("\nNOT_A_VALID_PICKUP_POINT\n\n");
                next;
            }

            my $r;
            if ($bib) {
                $r = place_hold('T', $bib, $patron, $pickup);
            } elsif ($copy) {
                $r = place_hold('C', $copy, $patron, $pickup);
            }
            print("\n$r\n\n");

        } elsif ($input eq '4') {
            my $p = prompt('patron');
            next if ($p =~ /^[qQ]$/);

            my $c = prompt('copy');
            next if ($c =~ /^[qQ]$/);

            my $r = checkout($c, $p);
            if ($r eq 'COPY_IN_TRANSIT') {
                my $copy = copy_from_barcode($c);
                my $transit = fetch_transit_by_copy($copy);
                if ($transit->dest == $ou->id) {
                    my $rez = receive_copy_transit($copy);
                    $r = checkout($c, $p) if ($rez->{textcode} eq 'SUCCESS');
                }
                elsif ($transit->source == $ou->id) {
                    $r = abort_copy_transit($copy);
                    $r = checkout($c, $p);
                }
            }
            print("\n$r\n\n");

        } elsif ($input eq '5') {
            my $c = prompt('copy');
            next if ($c =~ /^[Qq]$/);
            my $r = checkin($c, $ou);
            print("\n$r\n\n");

        } elsif ($input eq '6') {
            my $t = prompt('title');
            my $cn = prompt('callnumber');
            next if ($cn =~ /^[Qq]$/);
            my $c = prompt('copy');
            next if ($c =~ /^[Qq]$/);

            my $r = create_copy($t, $cn, $c, $ou);
            print("\n$r\n\n");
        } elsif ($input eq '7') {
            my $c = prompt('copy');
            next if ($c =~ /^[Qq]$/);

            my $copy = copy_from_barcode($c);
            if (ref($copy) eq 'HASH') {
                printf("\n%s\n\n", $copy->{textcode});
                next;
            }
            print("ASSET_COPY_NOT_FOUND\n\n") unless ($copy && $copy->circ_lib == $ou->id);

            my $r = delete_copy($copy);
            print("\n$r\n\n");
        }
    }
    # Clear any SIGALRM timers.
    alarm(0);
    logout();
} else {
    die("Hes's dead, Jim.");
}

# Functions to print the menus/command prompts:

# Print a prompt, wait for and validate input.
sub prompt {
    my $name = shift;
    my @info = @{ $prompts{$name} };
    my $input;
    # Reset our SIGALRM timer:
    alarm($timeout);
    while (1) {
        printf("%s ", $info[0]);
        $input = <STDIN>;
        chomp($input);
        if ($input =~ /$info[1]/) {
            last;
        } else {
            printf("%s\n", $info[2]);
        }
    }
    return $input;
}

# The main menu
sub print_main_menu {
    my $text =<<EOMAINMENU;
Main Menu
1. Retrieve Patron
2. Retrieve Bibliographic ID
3. Place Hold
4. Checkout Copy
5. Checkin Copy
6. Create Temporary Copy
7. Delete Temporary Copy
Q. Quit
EOMAINMENU
    ; # stupid perl-mode
    print("$text");
}

# Place Hold Identifier Menu
sub print_hold_identifier_menu {
    my $text =<<EOIDENTIFIERMENU;
Place Hold
Choose Target Identifier
1. Bibliographic Record ID
2. Copy Barcode
EOIDENTIFIERMENU
; # stupid perl-mode
    print("$text");
}

# Some useful functions needed by the program.

# Login to the OpenSRF system/Evergreen.
#
# Arguments are:
# username
# password
# workstation
#
# Returns a hash with the authtoken, authtime, and expiration (time in
# seconds since 1/1/1970).
sub login {
    my ($uname, $password, $workstation) = @_;

    my $seed = OpenSRF::AppSession
        ->create('open-ils.auth')
        ->request('open-ils.auth.authenticate.init', $uname)
        ->gather(1);

    return undef unless $seed;

    my $response = OpenSRF::AppSession
        ->create('open-ils.auth')
        ->request('open-ils.auth.authenticate.complete',
                  { username => $uname,
                    password => md5_hex($seed . md5_hex($password)),
                    type => 'staff',
                    workstation => $workstation })
        ->gather(1);

    return undef unless $response;

    my %result;
    $result{'authtoken'} = $response->{payload}->{authtoken};
    $result{'authtime'} = $response->{payload}->{authtime};
    $result{'expiration'} = time() + $result{'authtime'} if (defined($result{'authtime'}));
    return %result;
}

# Logout/destroy the OpenSRF session
#
# Argument is
# none
#
# Returns
# Does not return anything
sub logout {
    if (time() < $session{'expiration'}) {
        my $response = OpenSRF::AppSession
            ->create('open-ils.auth')
            ->request('open-ils.auth.session.delete', $session{authtoken})
            ->gather(1);
        if ($response) {
            print("Logout successful. Good-bye.\n");
            exit(0);
        } else {
            die("Logout unsuccessful. Good-bye, anyway.");
        }
    }
}

# Retrieve the logged in user.
#
# Argument
#
# Returns
# User logged via issa.
sub get_session {
    my $response = OpenSRF::AppSession->create('open-ils.auth')
        ->request('open-ils.auth.session.retrieve', $session{authtoken})->gather(1);
    return $response;
}

# Get actor.org_unit from the shortname
#
# Arguments
# org_unit shortname
#
# Returns
# Fieldmapper aou object
# or HASH on error
sub org_unit_from_shortname {
    check_session_time();
    my ($shortname) = @_;
    my $ou = OpenSRF::AppSession->create('open-ils.actor')
        ->request('open-ils.actor.org_unit.retrieve_by_shortname', $shortname)
        ->gather(1);
    return $ou;
}

# Checkout a copy to a patron
#
# Arguments
# copy barcode
# patron barcode
#
# Returns
# textcode of the OSRF response.
sub checkout {
    check_session_time();
    my ($copy_barcode, $patron_barcode) = @_;

    # Check for copy:
    my $copy = copy_from_barcode($copy_barcode);
    unless (defined($copy) && blessed($copy)) {
        return 'COPY_BARCODE_NOT_FOUND';
    }

    # Check for user
    my $uid = user_id_from_barcode($patron_barcode);
    return 'PATRON_BARCODE_NOT_FOUND' if (ref($uid));

    my $response = OpenSRF::AppSession->create('open-ils.circ')
        ->request('open-ils.circ.checkout.full.override', $session{authtoken},
                  { copy_barcode => $copy_barcode,
                    patron_barcode => $patron_barcode })
        ->gather(1);
    return $response->{textcode};
}

# Check a copy in at an org_unit
#
# Arguments
# copy barcode
# org_unit
#
# Returns
# "SUCCESS" on success
# textcode of a failed OSRF request
# 'COPY_NOT_CHECKED_OUT' when the copy is not checked out or not
# checked out to the user's work_ou
sub checkin {
    check_session_time();
    my ($barcode, $where) = @_;

    my $copy = copy_from_barcode($barcode);
    return $copy->{textcode} unless (blessed $copy);

    return 'COPY_NOT_CHECKED_OUT' unless ($copy->status == OILS_COPY_STATUS_CHECKED_OUT);

    my $e = new_editor(authtoken=>$session{authtoken});
    return $e->event->{textcode} unless ($e->checkauth);

    my $circ = $e->search_action_circulation([ { target_copy => $copy->id, xact_finish => undef } ])->[0];
    return 'COPY_NOT_CHECKED_OUT' unless (defined($circ) && $circ->circ_lib == $where->id);

    my $r = OpenSRF::AppSession->create('open-ils.circ')
        ->request('open-ils.circ.checkin', $session{authtoken}, { barcode => $barcode, void_overdues => 1 })
        ->gather(1);
    return 'SUCCESS' if ($r->{textcode} eq 'ROUTE_ITEM');
    return $r->{textcode};
}

# Abort a copy transit
#
# Arguments
# copy
#
# Returns the OSRF response, which could be a scalar or a hash
sub abort_copy_transit {
    check_session_time();
    my ($copy) = @_;
    my $response = OpenSRF::AppSession->create('open-ils.circ')
        ->request('open-ils.circ.transit.abort', $session{authtoken},
                  { copyid => $copy->id })
        ->gather(1);
    return $response;
}

# Receive a copy transit
#
# Arguments
# copy
#
# Returns the OSRF response, which could be a scalar or a hash
sub receive_copy_transit {
    check_session_time();
    my ($copy) = @_;
    my $response = OpenSRF::AppSession->create('open-ils.circ')
        ->request('open-ils.circ.copy_transit.receive', $session{authtoken},
                  { copyid => $copy->id })
        ->gather(1);
    return $response;
}

# Fetch a transit object by copy
#
# Arguments
# copy
#
# Returns
# transit object
# or event hash on error
sub fetch_transit_by_copy {
    check_session_time();
    my ($copy) = @_;
    my $response = OpenSRF::AppSession->create('open-ils.circ')
        ->request('open-ils.circ.open_copy_transit.retrieve', $session{authtoken}, $copy->id)
        ->gather(1);
    return $response;
}

# Get biblio.record_entry from asset.copy.barcode.
# Arguments
# copy barcode
#
# Returns
# biblio.record_entry fieldmapper object or
# hash on error
sub bre_from_barcode {
    check_session_time();
    my ($barcode) = @_;
    my $response = OpenSRF::AppSession->create('open-ils.storage')
        ->request('open-ils.storage.biblio.record_entry.retrieve_by_barcode', $barcode)
        ->gather(1);
    return $response;
}

# Get asset.copy from asset.copy.barcode.
# Arguments
# copy barcode
#
# Returns
# asset.copy fieldmaper object
# or hash on error
sub copy_from_barcode {
    check_session_time();
    my ($barcode) = @_;
    my $response = OpenSRF::AppSession->create('open-ils.search')
        ->request('open-ils.search.asset.copy.find_by_barcode', $barcode)
        ->gather(1);
    return $response;
}

# Get actor.usr.id from barcode.
# Arguments
# patron barcode
#
# Returns
# actor.usr.id
# or hash on error
sub user_id_from_barcode {
    check_session_time();
    my ($barcode) = @_;

    my $response;

    my $e = new_editor(authtoken=>$session{authtoken});
    return $response unless ($e->checkauth);

    my $card = $e->search_actor_card({barcode => $barcode, active => 't'});
    return $e->event unless($card);

    $response = $card->[0]->usr if (@$card);

    $e->finish;

    return $response;
}

# Flesh user information
# Arguments
# actor.usr.id
#
# Returns
# fieldmapped, fleshed user or
# event hash on error
sub flesh_user {
    check_session_time();
    my ($id) = @_;
    my $response = OpenSRF::AppSession->create('open-ils.actor')
        ->request('open-ils.actor.user.fleshed.retrieve', $session{'authtoken'}, $id,
                   [ 'card', 'cards', 'standing_penalties', 'home_ou' ])
        ->gather(1);
    return $response;
}

# Place a hold for a patron.
#
# Arguments
# Type of hold
# Target object appropriate for type of hold
# Patron for whom the hold is place
# OU where hold is to be picked up
#
# Returns
# "SUCCESS" on success
# textcode of a failed OSRF request
# "HOLD_TYPE_NOT_SUPPORTED" if the hold type is not supported
# (Currently only support 'T' and 'C')
sub place_hold {
    check_session_time();
    my ($type, $target, $patron, $pickup_ou) = @_;

    my $ou = org_unit_from_shortname($work_ou); # $work_ou is global
    my $ahr = Fieldmapper::action::hold_request->new;
    $ahr->hold_type($type);
    if ($type eq 'C') {
        # Check if we own the copy.
        if ($ou->id == $target->circ_lib) {
            # We own it, so let's place a copy hold.
            $ahr->target($target->id);
            $ahr->current_copy($target->id);
        } else {
            # We don't own it, so let's place a title hold instead.
            my $bib = bre_from_barcode($target->barcode);
            $ahr->target($bib->id);
            $ahr->hold_type('T');
        }
    } elsif ($type eq 'T') {
        $ahr->target($target);
    } else {
        return "HOLD_TYPE_NOT_SUPPORTED";
    }
    $ahr->usr($patron->id);
    $ahr->pickup_lib($pickup_ou->id);
    if (!$patron->email) {
        $ahr->email_notify('f');
        $ahr->phone_notify($patron->day_phone) if ($patron->day_phone);
    } else {
        $ahr->email_notify('t');
    }

    # We must have a title hold and we want to change the hold
    # expiration date if we're sending the copy to the VC.
    set_title_hold_expiration($ahr) if ($ahr->pickup_lib == $ou->id);

    my $params = { pickup_lib => $ahr->pickup_lib, patronid => $ahr->usr, hold_type => $ahr->hold_type };

    if ($ahr->hold_type eq 'C') {
        $params->{copy_id} = $ahr->target;
    } else {
        $params->{titleid} = $ahr->target;
    }

    my $r = OpenSRF::AppSession->create('open-ils.circ')
        ->request('open-ils.circ.title_hold.is_possible', $session{authtoken}, $params)
            ->gather(1);

    if ($r->{textcode}) {
        return $r->{textcode};
    } elsif ($r->{success}) {
        $r = OpenSRF::AppSession->create('open-ils.circ')
            ->request('open-ils.circ.holds.create.override', $session{authtoken}, $ahr)
                ->gather(1);

        my $returnValue = "SUCCESS";
        if (ref($r) eq 'HASH') {
            $returnValue = ($r->{textcode} eq 'PERM_FAILURE') ? $r->{ilsperm} : $r->{textcode};
            $returnValue =~ s/\.override$// if ($r->{textcode} eq 'PERM_FAILURE');
        }
        return $returnValue;
    } else {
        return 'HOLD_NOT_POSSIBLE';
    }
}

# Set the expiration date on title holds
#
# Argument
# Fieldmapper action.hold_request object
#
# Returns
# Nothing
sub set_title_hold_expiration {
    my $hold = shift;
    if ($title_holds->{unit} && $title_holds->{duration}) {
        my $expiration = DateTime->now(time_zone => $tz);
        $expiration->add($title_holds->{unit} => $title_holds->{duration});
        $hold->expire_time($expiration->iso8601());
    }
}

# Delete a copy created by URSA
#
# Argument
# Fieldmapper asset.copy object
#
# Returns
# "SUCCESS" on success
# Event textcode if an error occurs
sub delete_copy {
    check_session_time();
    my ($copy) = @_;

    my $e = new_editor(authtoken=>$session{authtoken});
    return $e->event->{textcode} unless ($e->checkauth);

    # Get the calnumber
    my $vol = $e->retrieve_asset_call_number($copy->call_number);
    return $e->event->{textcode} unless ($vol);

    # Get the biblio.record_entry
    my $bre = $e->retrieve_biblio_record_entry($vol->record);
    return $e->event->{textcode} unless ($bre);

    # Delete everything in a transaction and rollback if anything fails.
    $e->xact_begin;
    my $r; # To hold results of editor calls
    $r = $e->delete_asset_copy($copy);
    unless ($r) {
        my $lval = $e->event->{textcode};
        $e->rollback;
        return $lval;
    }
    my $list = $e->search_asset_copy({call_number => $vol->id, deleted => 'f'});
    unless (@$list) {
        $r = $e->delete_asset_call_number($vol);
        unless ($r) {
            my $lval = $e->event->{textcode};
            $e->rollback;
            return $lval;
        }
        $list = $e->search_asset_call_number({record => $bre->id, deleted => 'f'});
        unless (@$list) {
            $bre->deleted('t');
            $r = $e->update_biblio_record_entry($bre);
            unless ($r) {
                my $lval = $e->event->{textcode};
                $e->rollback;
                return $lval;
            }
        }
    }
    $e->commit;
    return 'SUCCESS';
}

# Create a copy and marc record
#
# Arguments
# title
# call number
# copy barcode
#
# Returns
# bib id on succes
# event textcode on failure
sub create_copy {
    check_session_time();
    my ($title, $callnumber, $barcode, $ou) = @_;

    my $e = new_editor(authtoken=>$session{authtoken});
    return $e->event->{textcode} unless ($e->checkauth);

    my $r = $e->allowed(['CREATE_COPY', 'CREATE_MARC', 'CREATE_VOLUME']);
    if (ref($r) eq 'HASH') {
        return $r->{textcode} . ' ' . $r->{ilsperm};
    }

    # Check if the barcode exists in asset.copy and bail if it does.
    my $list = $e->search_asset_copy({deleted => 'f', barcode => $barcode});
    if (@$list) {
        $e->finish;
        return 'BARCODE_EXISTS';
    }

    # Create MARC record
    my $record = MARC::Record->new();
    $record->encoding('UTF-8');
    $record->leader('00881nam a2200193   4500');
    my $datespec = strftime("%Y%m%d%H%M%S.0", localtime);
    my @fields = ();
    push(@fields, MARC::Field->new('005', $datespec));
    push(@fields, MARC::Field->new('082', '0', '4', 'a' => $callnumber));
    push(@fields, MARC::Field->new('245', '0', '0', 'a' => $title));
    $record->append_fields(@fields);

    # Convert the record to XML
    my $xml = convert2marcxml($record);

    my $bre = OpenSRF::AppSession->create('open-ils.cat')
        ->request('open-ils.cat.biblio.record.xml.import', $session{authtoken}, $xml, $bre_source, 1)
        ->gather(1);
    return $bre->{textcode} if (ref($bre) eq 'HASH');

    # Create volume record
    my $vol = OpenSRF::AppSession->create('open-ils.cat')
        ->request('open-ils.cat.call_number.find_or_create', $session{authtoken}, $callnumber, $bre->id, $ou->id)
        ->gather(1);
    return $vol->{textcode} if ($vol->{textcode});

    # Retrieve the user
    my $user = get_session;
    # Create copy record
    my $copy = Fieldmapper::asset::copy->new();
    $copy->barcode($barcode);
    $copy->call_number($vol->{acn_id});
    $copy->circ_lib($ou->id);
    $copy->circulate('t');
    $copy->holdable('t');
    $copy->opac_visible('f');
    $copy->deleted('f');
    $copy->fine_level(2);
    $copy->loan_duration(2);
    $copy->location(1);
    $copy->status(0);
    $copy->editor($user->id);
    $copy->creator($user->id);

    # Add the configured stat cat entries.
    my @stat_cats;
    my $nodes = $xpath->find("/issa/copy/stat_cat_entry");
    foreach my $node ($nodes->get_nodelist) {
        next unless ($node->isa('XML::XPath::Node::Element'));
        my $stat_cat_id = $node->getAttribute('stat_cat');
        my $value = $node->string_value();
        # Need to search for an existing asset.stat_cat_entry
        my $asce = $e->search_asset_stat_cat_entry({'stat_cat' => $stat_cat_id, 'value' => $value})->[0];
        unless ($asce) {
            # if not, create a new one and use its id.
            $asce = Fieldmapper::asset::stat_cat_entry->new();
            $asce->stat_cat($stat_cat_id);
            $asce->value($value);
            $asce->owner($ou->id);
            $e->xact_begin;
            $asce = $e->create_asset_stat_cat_entry($asce);
            $e->xact_commit;
        }
        push(@stat_cats, $asce);
    }

    $e->xact_begin;
    $copy = $e->create_asset_copy($copy);
    if (scalar @stat_cats) {
        foreach my $asce (@stat_cats) {
            my $ascecm = Fieldmapper::asset::stat_cat_entry_copy_map->new();
            $ascecm->stat_cat($asce->stat_cat);
            $ascecm->stat_cat_entry($asce->id);
            $ascecm->owning_copy($copy->id);
            $ascecm = $e->create_asset_stat_cat_entry_copy_map($ascecm);
        }
    }
    $e->commit;
    return $e->event->{textcode} unless ($r);

    return 'SUCCESS';
}

# Convert a MARC::Record to XML for Evergreen
#
# Stolen from MVLC's Safari Load program which copied it from some
# code in the Open-ILS example import scripts.
#
# Argument
# A MARC::Record object
#
# Returns
# String with XML for the MARC::Record as Evergreen likes it
sub convert2marcxml {
    my $input = shift;
    (my $xml = $input->as_xml_record()) =~ s/\n//sog;
    $xml =~ s/^<\?xml.+\?\s*>//go;
    $xml =~ s/>\s+</></go;
    $xml =~ s/\p{Cc}//go;
    $xml = OpenILS::Application::AppUtils->entityize($xml);
    $xml =~ s/[\x00-\x1f]//go;
    return $xml;
}

# Check if an org_unit can have users
#
# Argument
# Fieldmapper org_unit object
#
# Returns
# 1 if true
# 0 if false
sub can_have_users {
    check_session_time();
    my ($ou) = @_;
    my $e = new_editor(authtoken=>$session{authtoken});
    die ("Something fascinating happened.") unless ($e->checkauth);
    my $aout = $e->retrieve_actor_org_unit_type($ou->ou_type);
    return $aout->can_have_users;
}

# Check the time versus the session expiration time and login again if
# the session has expired, consequently resetting the session
# paramters. We want to run this before doing anything that requires
# us to have a current session in OpenSRF.
#
# Arguments
# none
#
# Returns
# Nothing
sub check_session_time {
    if (time() > $session{'expiration'}) {
        %session = login($username, $password, $workstation);
        if (!%session) {
            die("Failed to reinitialize the session after expiration.");
        }
    }
}

# You can add custom prompt messages in a <prompts> block in the
# configuration file.
#
# Each prompt can be defined with a cusom tag named for the prompt key
# in the %prompts hash in issa.pl. The prompt text, if different from
# the default, can go in a prompt tag. The regex, if different from
# the default, can go in a regex tag. The message goes in a message
# tag.
#
# You want to make certain that your regex allows a single letter Q
# (either upper or lower case) or there may be no escape from the
# program.
#
# Here's an example for the patron barcode prompt that changes all
# parts of the entry:
#
# <prompts>
# <patron>
# <prompt>Patron Barcode:</prompt>
# <regex>^(?:2\d{13}|[Qq])$</regex>
# <message>A patron barcode must be 14 digits and begin with a 2.</message>
# </patron>
# </prompts>
#
# You can have multiple prompts blocks or put all the custom prompt
# tags in a single block.
#
# It doesn't make sense to configure a custom prompt more than once,
# but if you do, the one that appears last in the file will take
# precedence over all previous ones.
sub customize_prompts {
    my $nodeset = $xpath->findnodes('/issa/prompts');
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->isa('XML::XPath::Node::Element')) {
            foreach my $child ($node->getChildNodes) {
                if ($child->isa('XML::XPath::Node::Element')) {
                    my $key = $child->getLocalName;
                    foreach my $gchild ($child->getChildNodes) {
                        if ($gchild->isa('XML::XPath::Node::Element')) {
                            my $tag = $gchild->getLocalName;
                            my $value = $gchild->string_value;
                            $prompts{$key}->[0] = $value if ($tag eq 'prompt' && defined($prompts{$key}));
                            $prompts{$key}->[1] = $value if ($tag eq 'regex' && defined($prompts{$key}));
                            $prompts{$key}->[2] = $value if ($tag eq 'message' && defined($prompts{$key}));
                        }
                    }
                }
            }
        }
    }
}
