// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialPayroll is ZamaEthereumConfig {

    enum Role { None, Employee, Manager, Admin }

    mapping(address => Role) public roles;

    mapping(address => euint64) private salaries;
    mapping(address => euint64) private pendingPayments;
    euint64 private totalPayrollCommitted;

    struct PaySchedule {
        uint256 intervalSeconds;
        uint256 lastPaidAt;
        bool    active;
    }

    mapping(address => PaySchedule) public schedules;
    address[] private employeeList;
    mapping(address => bool) private isEmployee;

    mapping(bytes32 => bool) private _usedDecryptionProofs;

    event SalarySet(address indexed employee, bytes32 encryptedSalaryHandle);
    event PaymentApproved(address indexed employee, bytes32 encryptedAmountHandle);
    event EmployeeAdded(address indexed employee);
    event EmployeeRemoved(address indexed employee);
    event RoleGranted(address indexed account, Role role);
    event PayrollTotalUpdated(bytes32 encryptedTotalHandle);
    event PayrollReportFinalized(uint64 clearTotal, uint256 timestamp);

    modifier onlyRole(Role required) {
        require(roles[msg.sender] >= required, "CPE: insufficient role");
        _;
    }

    modifier onlyAdmin() {
        require(roles[msg.sender] == Role.Admin, "CPE: admin only");
        _;
    }

    constructor() {
        roles[msg.sender] = Role.Admin;
        emit RoleGranted(msg.sender, Role.Admin);
    }

    function grantRole(address account, Role role) external onlyAdmin {
        require(role != Role.None, "CPE: cannot grant None");
        roles[account] = role;
        emit RoleGranted(account, role);
    }

    function revokeRole(address account) external onlyAdmin {
        require(account != msg.sender, "CPE: cannot revoke own admin");
        roles[account] = Role.None;
    }

    function addEmployee(address employee) external onlyRole(Role.Manager) {
        require(!isEmployee[employee], "CPE: already employee");
        require(
            roles[employee] == Role.None || roles[employee] == Role.Employee,
            "CPE: address has conflicting role"
        );

        if (roles[employee] == Role.None) {
            roles[employee] = Role.Employee;
            emit RoleGranted(employee, Role.Employee);
        }

        isEmployee[employee] = true;
        employeeList.push(employee);

        schedules[employee] = PaySchedule({
            intervalSeconds: 30 days,
            lastPaidAt: block.timestamp,
            active: false
        });

        emit EmployeeAdded(employee);
    }

    function removeEmployee(address employee) external onlyRole(Role.Manager) {
        require(isEmployee[employee], "CPE: not an employee");
        isEmployee[employee] = false;
        schedules[employee].active = false;

        for (uint256 i = 0; i < employeeList.length; i++) {
            if (employeeList[i] == employee) {
                employeeList[i] = employeeList[employeeList.length - 1];
                employeeList.pop();
                break;
            }
        }

        emit EmployeeRemoved(employee);
    }

    function setPayInterval(address employee, uint256 intervalSeconds)
        external onlyRole(Role.Manager)
    {
        require(isEmployee[employee], "CPE: not an employee");
        require(intervalSeconds >= 1 days, "CPE: interval too short");
        schedules[employee].intervalSeconds = intervalSeconds;
    }

    function setSalary(
        address employee,
        externalEuint64 encSalary,
        bytes calldata proof
    ) external onlyRole(Role.Manager) {
        require(isEmployee[employee], "CPE: not an employee");

        euint64 salary = FHE.fromExternal(encSalary, proof);

        salaries[employee] = salary;
        FHE.allowThis(salaries[employee]);
        FHE.allow(salaries[employee], employee);
        FHE.allow(salaries[employee], msg.sender);

        schedules[employee].active = true;

        emit SalarySet(employee, FHE.toBytes32(salaries[employee]));
    }

    function grantSalaryReadAccess(address employee, address manager)
        external onlyAdmin
    {
        require(isEmployee[employee], "CPE: not an employee");
        require(roles[manager] >= Role.Manager, "CPE: target is not manager");
        require(FHE.isInitialized(salaries[employee]), "CPE: salary not set");
        FHE.allow(salaries[employee], manager);
    }

    function approvePayment(address employee)
        external onlyRole(Role.Manager)
    {
        require(isEmployee[employee], "CPE: not an employee");
        require(schedules[employee].active, "CPE: schedule not active");
        require(
            block.timestamp >= schedules[employee].lastPaidAt + schedules[employee].intervalSeconds,
            "CPE: payment interval not elapsed"
        );
        require(FHE.isInitialized(salaries[employee]), "CPE: salary not set");

        euint64 salary = salaries[employee];

        euint64 newPending = FHE.add(pendingPayments[employee], salary);
        ebool pendingOverflow = FHE.lt(newPending, pendingPayments[employee]);
        pendingPayments[employee] = FHE.select(
            pendingOverflow,
            pendingPayments[employee],
            newPending
        );
        FHE.allowThis(pendingPayments[employee]);
        FHE.allow(pendingPayments[employee], employee);

        euint64 newTotal = FHE.add(totalPayrollCommitted, salary);
        ebool totalOverflow = FHE.lt(newTotal, totalPayrollCommitted);
        totalPayrollCommitted = FHE.select(
            totalOverflow,
            totalPayrollCommitted,
            newTotal
        );
        FHE.allowThis(totalPayrollCommitted);

        schedules[employee].lastPaidAt = block.timestamp;

        emit PaymentApproved(employee, FHE.toBytes32(pendingPayments[employee]));
        emit PayrollTotalUpdated(FHE.toBytes32(totalPayrollCommitted));
    }

    function approveAllEligiblePayments() external onlyAdmin {
        for (uint256 i = 0; i < employeeList.length; i++) {
            address emp = employeeList[i];
            if (
                schedules[emp].active &&
                FHE.isInitialized(salaries[emp]) &&
                block.timestamp >= schedules[emp].lastPaidAt + schedules[emp].intervalSeconds
            ) {
                euint64 salary = salaries[emp];

                euint64 newPending = FHE.add(pendingPayments[emp], salary);
                ebool overflow = FHE.lt(newPending, pendingPayments[emp]);
                pendingPayments[emp] = FHE.select(overflow, pendingPayments[emp], newPending);
                FHE.allowThis(pendingPayments[emp]);
                FHE.allow(pendingPayments[emp], emp);

                euint64 newTotal = FHE.add(totalPayrollCommitted, salary);
                ebool totalOverflow = FHE.lt(newTotal, totalPayrollCommitted);
                totalPayrollCommitted = FHE.select(totalOverflow, totalPayrollCommitted, newTotal);
                FHE.allowThis(totalPayrollCommitted);

                schedules[emp].lastPaidAt = block.timestamp;

                emit PaymentApproved(emp, FHE.toBytes32(pendingPayments[emp]));
            }
        }
        emit PayrollTotalUpdated(FHE.toBytes32(totalPayrollCommitted));
    }

    function revealPayrollTotal() external onlyAdmin {
        require(FHE.isInitialized(totalPayrollCommitted), "CPE: no payroll committed");
        FHE.makePubliclyDecryptable(totalPayrollCommitted);
    }

    function finalizePayrollReport(
        uint64 clearTotal,
        bytes memory decryptionProof
    ) external onlyAdmin {
        bytes32 proofHash = keccak256(decryptionProof);
        require(!_usedDecryptionProofs[proofHash], "CPE: proof already used");
        _usedDecryptionProofs[proofHash] = true;

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(totalPayrollCommitted);

        bytes memory abiEncoded = abi.encode(clearTotal);
        FHE.checkSignatures(handles, abiEncoded, decryptionProof);

        emit PayrollReportFinalized(clearTotal, block.timestamp);
    }

    function getEncryptedSalary(address employee) external view returns (euint64) {
        require(
            msg.sender == employee ||
            roles[msg.sender] >= Role.Manager,
            "CPE: not authorized"
        );
        return salaries[employee];
    }

    function getEncryptedPendingPayment(address employee) external view returns (euint64) {
        require(
            msg.sender == employee ||
            roles[msg.sender] >= Role.Manager,
            "CPE: not authorized"
        );
        return pendingPayments[employee];
    }

    function getEncryptedPayrollTotal() external view onlyAdmin returns (euint64) {
        return totalPayrollCommitted;
    }

    function getEmployeeList() external view onlyRole(Role.Manager) returns (address[] memory) {
        return employeeList;
    }

    function getSchedule(address employee) external view returns (PaySchedule memory) {
        require(
            msg.sender == employee || roles[msg.sender] >= Role.Manager,
            "CPE: not authorized"
        );
        return schedules[employee];
    }
}
