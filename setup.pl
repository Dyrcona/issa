#!/usr/bin/perl
# Copyright © 2011 Jason J.A. Stephenson <jason@sigio.com>
# Portions Copyright © 2012 Merrimack Valley Library Consortium
# <jstephenson@mvlc.org>
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
use OpenSRF::System;
use OpenSRF::Utils::SettingsClient;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use Digest::MD5 qw/md5_hex/;
use File::Basename;

# First, request the bootstrap file so we can run and configure issa.
my $bootstrap;
until ($bootstrap) {
    $bootstrap = get_bootstrap();
}
# Set $bootstrap_dir that we'll use when installing the issa config:
my $bootstrap_dir = dirname($bootstrap);
# Set prefix_dir by pulling of first path component of bootstrap_dir:
my $prefix_dir = $bootstrap_dir;
$prefix_dir =~ s/^(\/?[^\/]+).*$/$1/;

# Do client bootstrap.
OpenSRF::System->bootstrap_client(config_file => $bootstrap);

# Get settings client.
my $settings = OpenSRF::Utils::SettingsClient->new();

# Import the Fieldmapper IDL.
Fieldmapper->import(IDL => $settings->config_value("IDL"));

# Initialize CStoreEditor:
OpenILS::Utils::CStoreEditor->init;

# Login to the OpenSRF/Evergreen system.
my $authtoken = login();

# We'll do the Evergreen/database stuff, first.

# Create/identify a branch to use for the virtual catalog.
my $work_ou = create_or_select_work_ou();

# We were going to create the user here, but I couldn't get it to work
# and the project has already run over by at least 20 hours.

# We will create the permission grp for the issa staff user,
# though. This makes setting the proper permissions a snap.
my $perm_grp = create_profile_group($work_ou);

# Create/identify a workstation for the staff user.
my $workstation = create_workstation($work_ou);

# Tell them we are done.
print("Thank you! We have done all that we can to set up the issa org_unit," .
      "\npermission group and workstation. You will need to do the remainder" .
      "\nof the setup using the staff client.\n");

# logout
OpenSRF::AppSession->create('open-ils.auth')
    ->request('open-ils.auth.session.delete', $authtoken)->gather(1);

#
# Implemenation subroutines
#
# Queries the user to input the path to the OpenSRF bootstrap file:
sub get_bootstrap {
    my $bootstrap;
    my $continue = 1;
    do {
        print("Enter the full path to your OpenSRF bootstrap file:\n");
        my $input = <STDIN>;
        $bootstrap = trim($input);
        if (-f $bootstrap) {
            print("\nYou entered $bootstrap.\nIs this correct (Y|N)?\n");
            $input = <STDIN>;
            $continue = ($input !~ /^\s*Y/i);
        } else {
            print("File does not exist: $bootstrap!\n\n");
        }
    } while ($continue);
    return $bootstrap;
}

# Query the user for Evergreen credentials to use when logging in.
sub login {
    my $authtoken;
    do {
        cls();
        print("Please, login with the credentials of an account with" .
              " consortial administrator privileges.\n");
        print("\nUsername: ");
        my $username = <STDIN>;
        $username = trim($username);
        print("\nPassword: ");
        my $password = <STDIN>;
        $password = trim($password);
        if ($username && $password) {
            my $seed = OpenSRF::AppSession->create('open-ils.auth')
                ->request('open-ils.auth.authenticate.init', $username)
                    ->gather(1);
            my $response = OpenSRF::AppSession->create('open-ils.auth')
                ->request('open-ils.auth.authenticate.complete',
                          { username => $username, type => 'staff',
                            password => md5_hex($seed . md5_hex($password)) })
                    ->gather(1);
            $authtoken = $response->{payload}->{authtoken} if ($response);
        }
    } until ($authtoken);
    return $authtoken;
}

# Query the user to get or create a work org unit for the virtual catalog.
sub create_or_select_work_ou {
    my $work_ou;
    print("\nissa requires an org_unit for transactions, etc.\n");
    print("Do you have an existing org_unit that you wish to use or do you" .
          " need to create a new one?\n");
    do {
        print("\n 1. Choose existing org_unit.\n 2. Create a new one.\n");
        my $input = <STDIN>;
        $input = trim($input);
        if ($input eq '1') {
            $work_ou = choose_work_ou();
        } elsif ($input eq '2') {
            $work_ou = create_work_ou();
        }
    } until ($work_ou);
    return $work_ou;
}

# Prompt user for a work_ou shortname.
sub choose_work_ou {
    my $ou;
    # Was going to make this display a list of ous, but decided to
    # just prompt for a shortname, instead. We might add choosing from
    # a list as an option in the future.
    cls();
    print("Enter the shortname of an existing org_unit: ");
    my $input = <STDIN>;
    $input = trim($input);

    $ou = OpenSRF::AppSession->create('open-ils.cstore')
        ->request('open-ils.cstore.direct.actor.org_unit.search',
                  {'shortname' => $input, '+aout' => {'can_have_users' => 't',
                                                      'can_have_vols' => 't'}},
                  {'join' => {'aout' => {'field'=>'id', 'fkey'=>'ou_type'}}})
            ->gather(1);

    unless($ou) {
        print("\nOrg_unit with shortname $input not found.\n");
        print("It could be that this org_unit is not allowed to have users" .
              " and/or volumes.\n");
        print("The issa org_unit must be able to have both.\n");
    }
    return $ou;
}

# Create a work_ou.
sub create_work_ou {
    my $aout = select_eligible_aout();
    my $ou = create_aou_of_type($aout);
    return $ou;
}

# Search aou for eligible aous and return them in an array.
# A "eligible" aou must be able to have volumes and users.
sub get_eligible_aous {
    my @results;

    my $r = OpenSRF::AppSession->create('open-ils.cstore')
        ->request('open-ils.cstore.direct.actor.org_unit.search',
                  {'+aout' => {'can_have_users' => 't','can_have_vols' => 't'}},
                  {'join' => {'aout' => {'field'=>'id','fkey'=>'ou_type'}}});

    while (my $rez = $r->recv) {
        push(@results, $rez->{content}) if ($rez->{status} eq 'OK');
    }
    $r->finish;
    return @results;
}

# Search for aouts that can have users and volumes.
sub get_eligible_aouts {
    my @results;
    my $r = OpenSRF::AppSession->create('open-ils.cstore')
        ->request('open-ils.cstore.direct.actor.org_unit_type.search',
                  {'can_have_users' => 't', 'can_have_vols' => 't'});
    while (my $rez = $r->recv) {
        push(@results, $rez->{content}) if ($rez->{status} eq 'OK');
    }
    $r->finish;
    return @results;
}

# Select from the array of eligible aouts
sub select_eligible_aout {
    my $choice;
    my @aouts = get_eligible_aouts();
    my $c = 0;
    cls();
    do {
        print("Choose an org_unit_type from the list below:\n");
        foreach my $aout (@aouts) {
            $c++;
            print($c . ". " . $aout->name . "\n");
        }
        my $input = <STDIN>;
        $input = trim($input);
        if (int($input) && $input <= $c && $input > 0) {
            $choice = $aouts[$input - 1];
        }
    } until ($choice);
    return $choice;
}

# create an aou and put it in the database
sub create_aou_of_type {
    my $aout = shift;
    my ($aou, $parent);
    if ($aout->depth && $aout->parent) {
        $parent = create_or_select_parents($aout);
        cls();
    }
    $aou = Fieldmapper::actor::org_unit->new;
    $aou->parent_ou($parent->id) if ($parent);
    $aou->ou_type($aout->id);
    $aou->opac_visible('f');
    my $ou_type = $aout->name;
    my $input;
    do {
        print("Enter shortname for the new $ou_type: ");
        $input = <STDIN>;
        $input = trim($input);
    } until ($input);
    $aou->shortname($input);
    do {
        print("Enter name for the new $ou_type: ");
        $input = <STDIN>;
        $input = trim($input);
    } until ($input);
    $aou->name($input);
    my $editor = new_editor(authtoken=>$authtoken,xact=>1);
    die "CStoreEditor checkauth failed" unless ($editor->checkauth);
    $aou = $editor->create_actor_org_unit($aou);
    die $editor->event->{textcode} unless ($aou);
    $editor->finish;
    print("$ou_type " . $aou->name . " created!\n");
    return $aou;
}

# Used to create and/or select all parents required for an aou of a
# given aout. Returns the immediate parent aou created or selected.
sub create_or_select_parents {
    my $aout = shift;
    my $parent;
    cls();
    print("Org_units of type " . $aout->name . " require a parent.\n");
    print("Do you wish to select or create an appropriate parent org_unit?\n");
    my $input;
    do {
        print(" 1. Select existing org_unit.\n 2. Create a new org_unit.\n");
        $input = <STDIN>;
        $input = trim($input);
    } until ($input eq '1' || $input eq '2');

    my $parent_aout = OpenSRF::AppSession->create('open-ils.pcrud')
        ->request('open-ils.pcrud.retrieve.aout', $authtoken, $aout->parent)
            ->gather(1);

    die "Unable to find org_unit_type " . $aout->parent unless($parent_aout);

    if ($input eq '1') {
        $parent = select_aou_of_type($parent_aout);
    } else {
        $parent = create_aou_of_type($parent_aout);
    }
    return $parent;
}

# Select an aou of a given aout
sub select_aou_of_type {
    my $aout = shift;
    my (@aous, $choice);

    my $r = OpenSRF::AppSession->create('open-ils.cstore')
        ->request('open-ils.cstore.direct.actor.org_unit.search',
                  {'+aout' => {'id' => $aout->id}},
                  {'join' => {'aout' => {'field'=>'id','fkey'=>'ou_type'}}});
    while (my $rez = $r->recv) {
        push(@aous, $rez->{content}) if ($rez->{status} eq 'OK');
    }
    $r->finish;
    cls();
    my $input;
    do {
        print("Select an org_unit from the list below:\n");
        my $c = 0;
        foreach my $aou (@aous) {
            $c++;
            print($c . '. ' . $aou->shortname . ' ' . $aou->name . "\n");
        }
        $input = <STDIN>;
        $input = trim($input);
        $choice = $aous[$input - 1] if (int($input) && $input <= $c
                                        && $input > 0);
    } until ($choice);
    return $choice;
}

# Create or select a workstation for the issa user.
sub create_workstation {
    my $work_ou = shift;
    my $workstation;
    my $input;

    print("The issa user needs a workstation in order to login.\n");
    do {
        print("Do you wish to create one, now? (Y|N)\n");
        $input = <STDIN>;
        $input = trim($input);
    } until ($input =~ /^[yn].*/i);
    if ($input =~ /^y/i) {
        print("\nEnter a name for the workstation: ");
        $input = <STDIN>;
        $input = trim($input);
        my $name = $work_ou->shortname . '-' . $input;
        $workstation = Fieldmapper::actor::workstation->new;
        $workstation->owning_lib($work_ou->id);
        $workstation->name($name);
        my $editor = new_editor(authtoken=>$authtoken,xact=>1);
        die "CStoreEditor checkauth failed" unless ($editor->checkauth);
        $workstation = $editor->create_actor_workstation($workstation);
        die $editor->event->{textcode} unless ($workstation);
        $editor->finish;
        print("Workstation named $name created!\n");
    }

    return $workstation;
}


# Create the group for the issa "staff" user and ensure it has necessary perms.
sub create_profile_group {
    my $aou = shift;
    my $grp;

    print("The issa staff user requires a profile group with specific " .
          "permissions.\n");
    print("We'll create the group for you.\n");

    print("\nEnter a name for the new group: ");
    my $input = <STDIN>;
    my $name = trim($input);

    #Need a CStoreEditor
    my $editor = new_editor(authtoken=>$authtoken,xact=>1);
    die "CStoreEditor checkauth failed" unless($editor->checkauth);

    # We're going to need the aout information for the permissions:
    my $aout = $editor->retrieve_actor_org_unit_type($aou->ou_type);

    # Check if the COPY_HOLDS_FORCE permission exists.
    my $force_available = 0;
    my $chf = $editor->search_permission_perm_list({code=>'COPY_HOLDS_FORCE'});
    $force_available = 1 if ($chf && scalar @$chf);

    # Create the group application perm:
    my $grp_perm = Fieldmapper::permission::perm_list->new();
    $grp_perm->code('group_application.user.issa');
    $grp_perm->description('Application group for issa staff clients');
    $grp_perm = $editor->create_permission_perm_list($grp_perm);
    unless ($grp_perm) {
        $editor->rollback;
        die "Failed to create group_application perm";
    }

    # Create the group:
    $grp = Fieldmapper::permission::grp_tree->new;
    $grp->parent(1);
    $grp->name($name);
    $grp->usergroup('t');
    $grp->perm_interval('10 years');
    $grp->description('issa Staff Client');
    $grp->application_perm('group_application.user.issa');
    $grp->hold_priority(0);
    $grp = $editor->create_permission_grp_tree($grp);
    unless($grp) {
        $editor->rollback;
        die "Failed to create $name permission group";
    }

    # A map of the required permissions:
    my @required_perms = (
                          ['ABORT_TRANSIT', $aout->depth],
                          ['COPY_ALERT_MESSAGE.override', 0],
                          ['COPY_CHECKIN', $aout->depth],
                          ['COPY_CHECKOUT', $aout->depth],
                          ['COPY_HOLDS', 0],
                          ['COPY_TRANSIT_RECEIVE', $aout->depth],
                          ['CREATE_COPY', $aout->depth],
                          ['CREATE_COPY_STAT_CAT_ENTRY', $aout->depth],
                          ['CREATE_COPY_STAT_CAT_ENTRY_MAP', $aout->depth],
                          ['CREATE_COPY_TRANSIT', 0],
                          ['CREATE_MARC', 0],
                          ['CREATE_TRANSIT', 0],
                          ['CREATE_VOLUME', $aout->depth],
                          ['DELETE_COPY', $aout->depth],
                          ['DELETE_VOLUME', $aout->depth],
                          ['IMPORT_MARC', 0],
                          ['PATRON_EXCEEDS_CHECKOUT_COUNT.override', 0],
                          ['PATRON_EXCEEDS_OVERDUE_COUNT.override', 0],
                          ['PATRON_EXCEEDS_FINES.override', 0],
                          ['REQUEST_HOLDS', 0],
                          ['STAFF_LOGIN', 0],
                          ['TITLE_HOLDS', 0],
                          ['UPDATE_COPY', $aout->depth],
                          ['UPDATE_VOLUME', $aout->depth],
                          ['UPDATE_MARC', 0],
                          ['VIEW_HOLD', 0],
                          ['VIEW_HOLD_PERMIT', 0],
                          ['VIEW_PERMIT_CHECKOUT', 0],
                          ['VIEW_USER', 0],
                         );

    # Ask if they want to use COPY_HOLDS_FORCE permission.
    if ($force_available) {
        my $response;
        print("You can grant the COPY_HOLDS_FORCE permission to the $name "
                  . "group.\n");
        print("Doing so will cause issa's copies to be non-holdable and"
                  . "\nrequire issa to use force holds when placing holds"
                      . " on its copies for your patrons.\n");
        print("This has the intended effect of stopping library staff from"
                  . " placing holds on issa's copies.\n");
        do {
            print("\nDo you with to use force holds with issa? [y/n]: ");
            $response = <STDIN>;
        } until ($response && $response =~ /^[YynN]/);
        if ($response =~ /^[yY]/) {
            push(@required_perms, ['COPY_HOLDS_FORCE', $aout->depth]);
        }
    }

    # Create permission.grp_perm_map entries:
    foreach my $entry (@required_perms) {
        my $code = $entry->[0];
        my $depth = $entry->[1];
        # We'll create as many as we can an report any that fail.
        # retrieve the permission entry.
        my $perm = OpenSRF::AppSession->create('open-ils.cstore')
            ->request('open-ils.cstore.direct.permission.perm_list.search',
                      {'code' => $code})->gather(1);
        if ($perm) {
            my $pgpm = Fieldmapper::permission::grp_perm_map->new();
            $pgpm->grp($grp->id);
            $pgpm->perm($perm->id);
            $pgpm->depth($depth);
            $pgpm->grantable('f');
            $pgpm = $editor->create_permission_grp_perm_map($pgpm);
            print("Failed to map $code permission.\n") unless($pgpm);
        } else {
            print("Failed to find $code permission.\n");
        }
    }

    $editor->finish;

    return $grp;
}

#
# Some useful subroutines:
#
# Removes whitespace from both ends of a string:
sub trim {
    my $input = shift;
    $input =~ s/^\s*(\S.*?\S?)\s*$/$1/o;
    return $input;
}

# Clears the terminal screen.
sub cls {
    system("clear");
}
