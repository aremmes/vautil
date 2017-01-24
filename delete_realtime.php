<?php

/*
* Copyright © 2005 - 2011 CoreDial, LLC.
* All Rights Reserved.
*
* This software is the confidential and proprietary information
* of CoreDial, LLC and constitues trade secrets owned by
* CoreDial, LLC ("Confidential Information"). You shall not
* disclose such Confidentital Information and shall use it only
* in accordance with the terms of the license agreement you
* entered into with CoreDial, LLC.
*
*/

define('BASE_DIR', dirname(dirname(__FILE__)));
require_once BASE_DIR . '/public/common.php';
require_once BASE_DIR . '/application/models/codegen/Codegen.inc.php';

// Fudge the user object so the E911 has somebody to blame when it writes to 
// the logfile
$userObject = new UserObject();
$userObject->setUsername($argv[0]);
$customerId = $argv[2];

$customer = new Customer($customerId, $portalLink);
if ($customer->getCustomerId() > 1)
{
    echo "Running Realtime Delete for {$customer->getCompanyName()}...\n";
    $codegen_realtime = new CodegenRealtime($customer->getBranchId());
    $codegen_realtime->deleteDb($customer->getContext());
}
