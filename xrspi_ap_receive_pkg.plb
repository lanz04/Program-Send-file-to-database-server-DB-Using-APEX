create or replace PACKAGE BODY xrspi_ap_receive_pkg
IS
    l_file   UTL_FILE.file_type;

    /********************************************************************************
    * Project Name      : RSPI Reimplementation
    * Client Name       : Rumah Sakit Pondok Indah & Puri Indah
    * Description       : Send Receipt/Return Transaction to TrakCare
    *
    * Update history     Re-fix date       Person In Charge      Description
    * 1.0                28-Jun-2013       Henry Kusuma Wong     Initial Creation
    * 2.0                                  Alfonso,Sena          Update
    * 3.0                        10-DEC-2015     Alfonso         Update script for solving issue Reject Docket Number : If Partial receipt then duplicate Docket Number
    * 4.0                19-Dec-2022       Timotius              Multiple batch for receiving
    * 5.0                25-Nov-2026       IFM                   Change EBS to Fusion
    ********************************************************************************/
    /*
      FUNCTION f_upd_rcv_shipment_lines(l_rowid IN ROWID,
                                        l_error_message OUT VARCHAR2) RETURN BOOLEAN IS

      BEGIN

        UPDATE rcv_shipment_lines
           SET attribute15 = 'P'
         WHERE ROWID = l_rowid;

        RETURN TRUE;

        EXCEPTION WHEN OTHERS THEN
                       l_error_message := 'xrspi_ap_rcv_rtrn_pkg.sp_create_file.f_upd_rcv_shipment_lines: ' || SQLERRM;
                       RETURN FALSE;

      END;


    --- Function Update Attribute 14 for suffix Docket Number - add by Alfonso - 10-DEC-2015
    FUNCTION f_upd_rcv_shipment_lines_att14(l_rowid IN ROWID,
                                        l_ship_header_id IN NUMBER,
                                        l_error_message OUT VARCHAR2) RETURN BOOLEAN IS


        v_att14 NUMBER;
      BEGIN
            SELECT NVL(MAX(attribute14),0) -1
            INTO v_att14
            FROM rcv_shipment_lines WHERE shipment_header_id = l_ship_header_id;


        UPDATE rcv_shipment_lines
        SET attribute14 = v_att14
        WHERE shipment_header_id = l_ship_header_id
                    AND attribute14 IS NULL;


        RETURN TRUE;

        EXCEPTION WHEN OTHERS THEN
                       l_error_message := 'xrspi_ap_rcv_rtrn_pkg.sp_create_file.f_upd_rcv_shipment_lines_att14: ' || SQLERRM;
                       RETURN FALSE;

      END;


      FUNCTION f_open_file(l_type IN VARCHAR2,
                           l_filename IN VARCHAR2,
                           l_error_message OUT VARCHAR2) RETURN BOOLEAN IS

      BEGIN

        l_file := utl_file.fopen(CASE
                                   WHEN l_type = 'RECEIPT' THEN 'EXPORT_DIR_RECEIPT_ARCH'
                                   WHEN l_type = 'RETURN' THEN 'EXPORT_DIR_RETURN_ARCH'
                                 END, l_filename, 'W');

        RETURN TRUE;

        EXCEPTION WHEN utl_file.invalid_path THEN
                       l_error_message := 'Invalid path';
                       RETURN FALSE;
                  WHEN OTHERS THEN
                       l_error_message := 'sf_create_file.f_open: ' || SQLERRM;
                       RETURN FALSE;

      END;

      PROCEDURE sp_create_receive IS

        TYPE status_rec IS RECORD
        (
         b_error BOOLEAN := FALSE,
         b_debug BOOLEAN := FALSE
        );

        g_rec_status status_rec;

        c_receive_prefix CONSTANT VARCHAR2(13) := 'Good_Receive_';
        c_pondok_indah_prefix CONSTANT VARCHAR2(2) := 'PI';
        c_puri_indah_prefix CONSTANT VARCHAR2(2) := 'PU';
        c_bintaro_jaya_prefix CONSTANT VARCHAR2(2) := 'BI'; --Add  prefix code Bintaro Jaya by Ayu Ningtias 09Sept2016 Bintaro Interface
        v_seqnum VARCHAR2(13);-- add erwin 20231215
        --v_seqnum number;-- add erwin 20231215
        g_error_message xrspi_interface_log.message%TYPE;
        --g_filename VARCHAR2(31);
        g_filename VARCHAR2(35);--erwinn modi VARCHAR2(35)
        g_org_id_pondok_indah hr_operating_units.organization_id%TYPE;
        g_org_id_puri_indah hr_operating_units.organization_id%TYPE;
        g_org_id_bintaro_jaya hr_organization_units.organization_id%TYPE;

        FUNCTION f_get_operating_unit(l_org_id_pondok_indah OUT NUMBER,
                                      l_org_id_puri_indah OUT NUMBER,
                                      l_org_id_bintaro_jaya OUT NUMBER, --Add  out Org Id Bintaro Jaya by Ayu Ningtias 09Sept2016 Bintaro Interface
                                      l_error_message OUT VARCHAR2) RETURN BOOLEAN IS

        BEGIN

          SELECT MAX(org_id_pondok_indah) org_id_pondok_indah,
                 MAX(org_id_puri_indah) org_id_puri_indah,
                     MAX(org_id_bintaro_jaya) org_id_bintaro_jaya  --Add  out Org Id Bintaro Jaya by Ayu Ningtias 09Sept2016 Bintaro Interface
                INTO l_org_id_pondok_indah,
                     l_org_id_puri_indah,
                     l_org_id_bintaro_jaya  --Add  out Org Id Bintaro Jaya by Ayu Ningtias 09Sept2016 Bintaro Interface
                FROM (SELECT CASE WHEN name = 'PONDOK INDAH - FARMASI' THEN organization_id END org_id_pondok_indah,
                             CASE WHEN name = 'PURI INDAH - FARMASI' THEN organization_id END org_id_puri_indah,
                             CASE WHEN name = 'BINTARO JAYA - FARMASI' THEN organization_id END  org_id_bintaro_jaya  --Add  out Org Id Bintaro Jaya by Ayu Ningtias 09Sept2016 Bintaro Interface
                        FROM hr_all_organization_units
                       WHERE name IN ('PONDOK INDAH - FARMASI', 'PURI INDAH - FARMASI','BINTARO JAYA - FARMASI'));  --Add  where clause Bintaro Jaya by Ayu Ningtias 09Sept2016 Bintaro Interface


          RETURN TRUE;

          EXCEPTION WHEN no_data_found THEN
                         l_error_message := 'No Org ID for for [Name] = [RSPI-PONDOK INDAH], [RSPI-PURI INDAH] and [RSPI-BINTARO JAYA] in HR Operating Units';
                         RETURN FALSE;
                    WHEN OTHERS THEN
                         l_error_message := 'xrspi_interface.f_get_operating_unit: ' || SQLERRM;
                         RETURN FALSE;

        END;

        FUNCTION f_lock_rsl(l_shipment_header_id IN NUMBER) RETURN BOOLEAN IS

          TYPE t_rowid IS TABLE OF ROWID;
          l_rowid t_rowid;

        BEGIN

          SELECT ROWID
            BULK COLLECT INTO l_rowid
            FROM rcv_shipment_lines
           WHERE shipment_header_id = l_shipment_header_id
             FOR UPDATE NOWAIT;

          RETURN TRUE;

          EXCEPTION WHEN OTHERS THEN
                         RETURN FALSE;

        END;

      BEGIN

        g_rec_status.b_error := FALSE;

        IF NOT f_get_operating_unit(g_org_id_pondok_indah,
                                    g_org_id_puri_indah,
                                    g_org_id_bintaro_jaya,
                                    g_error_message) THEN
          g_rec_status.b_error := TRUE;
          IF g_rec_status.b_debug THEN
            dbms_output.put_line(g_error_message);
          END IF;
        END IF;

        IF NOT g_rec_status.b_error THEN

          FOR cur_receipt IN (SELECT receipt_num, shipment_header_id
                                FROM rcv_shipment_headers rsh
                               WHERE trunc(rsh.creation_date) = TRUNC(SYSDATE)
                                 AND EXISTS
                                     (SELECT 1
                                        FROM rcv_shipment_lines rsl
                                       WHERE rsl.attribute15 IS NULL
                                         AND rsh.shipment_header_id = rsl.shipment_header_id)
                                 AND EXISTS
                                     (SELECT 1
                                        FROM rcv_transactions rt
                                       WHERE rt.transaction_type = 'DELIVER'
                                         AND rsh.shipment_header_id = rt.shipment_header_id)) LOOP

            IF NOT f_lock_rsl(cur_receipt.shipment_header_id) THEN
              EXIT;
            END IF;

            --Generate Good Receive
            FOR cur_receipt_lines IN (SELECT l_rowid,
                                             COUNT(1) OVER (PARTITION BY 1) ctr,
                                             row_number() OVER (PARTITION BY 1 ORDER BY 1) rn,
                                             delivery_order_no || '^' ||
                                             vendor_code || '^' ||
                                             vendor_name || '^' ||
                                             receipt_date || '^' ||
                                             docket_number || '^' ||
                                             docket_date || '^' ||
                                             currency || '^' ||
                                             exchange_rate || '^' ||
                                             completed || '^' ||
                                             export_time || '^' ||
                                             transaction_user || '^' ||
                                             item_code || '^' ||
                                             item_description || '^' ||
                                             nvl(item_quantity, quantity) || '^' ||
                                             batch_no2 || '^' ||
                                             expiration_date2 || '^' ||
                                             uom_description || '^' ||
                                             receive_type || '^' ||
                                             location_code || '^' ||
                                             unit_cost || '^' ||
                                             remarks data_receipt
                                        FROM (SELECT A.l_rowid,
                                                     A.shipment_line_id,
                                                     '000INT' vendor_code,
                                                     'Interface Oracle' vendor_name,
                                                     to_char(A.transaction_date,'DD/MM/YYYY') docket_date,
                                                     CASE
                                                       WHEN A.organization_id = g_org_id_pondok_indah THEN c_pondok_indah_prefix
                                                       WHEN A.organization_id = g_org_id_puri_indah THEN c_puri_indah_prefix
                                                       WHEN a.organization_id = g_org_id_bintaro_jaya THEN c_bintaro_jaya_prefix
                                                      END || A.receipt_num||a.suffix docket_number,        -- add suffix by Alfonso 08DEC2015
                                                     'Rupiah' currency,
                                                     '1' exchange_rate,
                                                     'Y' completed,
                                                     'Interface Oracle' transaction_user,
                                                     A.segment1 item_code,
                                                     A.description item_description,
                                                     b.primary_quantity item_quantity,
                                                     b.lot_number batch_no,
                                                     to_char(b.expiration_date,'DD/MM/YYYY') expiration_date,
                                                     To_Char(TO_DATE(A.ATTRIBUTE10,'YYYY/MM/DD HH24:MI:SS'),'DD/MM/YYYY') expiration_date2, ----erwin 20211209
                                                     A.ATTRIBUTE11 AS batch_no2,----erwin 20211209
                                                     CASE
                                                       WHEN A.transaction_type = 'RETURN TO VENDOR' THEN A.primary_quantity * -1
                                                       ELSE A.primary_quantity
                                                     END quantity,
                                                     'Stock UOM' uom_description,
                                                     A.subinventory location_code,
                                                     A.comments remarks,
                                                     '0'unit_cost,
                                                     'NOR' receive_type,
                                                     to_char(SYSDATE, 'DD/MM/YYYY') export_time,
                                                     '' delivery_order_no,
                                                     '' receipt_date
                                                FROM (SELECT rsl.rowid l_rowid,
                                                             rsl.shipment_line_id,
                                                             rt.transaction_date,
                                                             cur_receipt.receipt_num receipt_num,
                                                             msb.segment1,
                                                             msb.description,
                                                             rt.transaction_type,
                                                             rt.primary_unit_of_measure,
                                                             rt.transaction_id,
                                                             rsl.item_id,
                                                             case when (rt.attribute7 is not null OR rt.attribute13 is not null)
                                                                     then apps.inv_convert.inv_um_convert (msb.inventory_item_id,  --Inventory Item Id
                                                                                                           NULL,                   --Precision
                                                                                                           NVL (rt.attribute12, 0),     --Quantity
                                                                                                           rt.uom_code,           --From UOM
                                                                                                           msb.primary_uom_code,                --To UOM
                                                                                                           NULL,               --From UOM Name
                                                                                                           NULL                 -- To UOM Name
                                                                                                          )
                                                                   else
                                                                     rt.primary_quantity end primary_quantity,
                                                             rt.organization_id,
                                                             rsl.to_subinventory subinventory,
                                                             rsl.comments,
                                                             (SELECT MAX(attribute14) FROM rcv_shipment_lines WHERE shipment_header_id = cur_receipt.shipment_header_id) - 1 AS suffix,     --add suffix by Alfonso 10-DEC-2015
                                                             rt.ATTRIBUTE10,--erwin 20211209
                                                             rt.ATTRIBUTE11 --erwin 20211209
                                                        FROM rcv_shipment_lines   rsl,
                                                             mtl_system_items_b   msb,
                                                             rcv_transactions rt
                                                       WHERE rt.transaction_type = 'DELIVER'
                                                         AND EXISTS
                                                             (
                                                              SELECT 1
                                                                FROM mtl_parameters mp
                                                               WHERE EXISTS
                                                                     (
                                                                      SELECT 1
                                                                        FROM fnd_flex_values ffv
                                                                       WHERE EXISTS
                                                                             (
                                                                              SELECT 1
                                                                                FROM fnd_flex_value_sets ffvs
                                                                               WHERE ffvs.flex_value_set_name = 'XRSPI_PO_FILTER_IO_RCV'
                                                                                 AND ffv.flex_value_set_id = ffvs.flex_value_set_id
                                                                             )
                                                                         AND mp.organization_code = ffv.flex_value
                                                                     )
                                                                 AND msb.organization_id = mp.organization_id
                                                             )
                                                         AND rsl.shipment_header_id = cur_receipt.shipment_header_id
                                                         AND rsl.item_id = msb.inventory_item_id
                                                         AND msb.organization_id = rt.organization_id
                                                         AND cur_receipt.shipment_header_id = rt.shipment_header_id
                                                         AND rsl.shipment_line_id = rt.shipment_line_id
                                                         AND rsl.attribute15 IS NULL
                                                         --AND rt.ATTRIBUTE11 IS NOT NULL
                                                         AND (rt.ATTRIBUTE11 IS NOT NULL OR rt.ATTRIBUTE11||rt.ATTRIBUTE15||rt.ATTRIBUTE9 IS NULL)
                                                      UNION ALL
                                                      SELECT rsl.rowid l_rowid,
                                                             rsl.shipment_line_id,
                                                             rt.transaction_date,
                                                             cur_receipt.receipt_num receipt_num,
                                                             msb.segment1,
                                                             msb.description,
                                                             rt.transaction_type,
                                                             rt.primary_unit_of_measure,
                                                             rt.transaction_id,
                                                             rsl.item_id,
                                                             apps.inv_convert.inv_um_convert (msb.inventory_item_id,  --Inventory Item Id
                                                                                                           NULL,                   --Precision
                                                                                                           NVL (rt.attribute13, 0),     --Quantity
                                                                                                           rt.uom_code,           --From UOM
                                                                                                           msb.primary_uom_code,                --To UOM
                                                                                                           NULL,               --From UOM Name
                                                                                                           NULL                 -- To UOM Name
                                                                                                          ) primary_quantity,
                                                             rt.organization_id,
                                                             rsl.to_subinventory subinventory,
                                                             rsl.comments,
                                                             (SELECT MAX(attribute14) FROM rcv_shipment_lines WHERE shipment_header_id = cur_receipt.shipment_header_id) - 1 AS suffix,     --add suffix by Alfonso 10-DEC-2015
                                                             rt.ATTRIBUTE14,--erwin 20211209
                                                             rt.ATTRIBUTE15 --erwin 20211209
                                                        FROM rcv_shipment_lines   rsl,
                                                             mtl_system_items_b   msb,
                                                             rcv_transactions rt
                                                       WHERE rt.transaction_type = 'DELIVER'
                                                         AND EXISTS
                                                             (
                                                              SELECT 1
                                                                FROM mtl_parameters mp
                                                               WHERE EXISTS
                                                                     (
                                                                      SELECT 1
                                                                        FROM fnd_flex_values ffv
                                                                       WHERE EXISTS
                                                                             (
                                                                              SELECT 1
                                                                                FROM fnd_flex_value_sets ffvs
                                                                               WHERE ffvs.flex_value_set_name = 'XRSPI_PO_FILTER_IO_RCV'
                                                                                 AND ffv.flex_value_set_id = ffvs.flex_value_set_id
                                                                             )
                                                                         AND mp.organization_code = ffv.flex_value
                                                                     )
                                                                 AND msb.organization_id = mp.organization_id
                                                             )
                                                         AND rsl.shipment_header_id = cur_receipt.shipment_header_id
                                                         AND rsl.item_id = msb.inventory_item_id
                                                         AND msb.organization_id = rt.organization_id
                                                         AND cur_receipt.shipment_header_id = rt.shipment_header_id
                                                         AND rsl.shipment_line_id = rt.shipment_line_id
                                                         AND rsl.attribute15 IS NULL
                                                         AND rt.ATTRIBUTE15 IS NOT NULL
                                                         UNION ALL
                                                         SELECT rsl.rowid l_rowid,
                                                             rsl.shipment_line_id,
                                                             rt.transaction_date,
                                                             cur_receipt.receipt_num receipt_num,
                                                             msb.segment1,
                                                             msb.description,
                                                             rt.transaction_type,
                                                             rt.primary_unit_of_measure,
                                                             rt.transaction_id,
                                                             rsl.item_id,
                                                             apps.inv_convert.inv_um_convert (msb.inventory_item_id,  --Inventory Item Id
                                                                                                           NULL,                   --Precision
                                                                                                           NVL (rt.attribute7, 0),     --Quantity
                                                                                                           rt.uom_code,           --From UOM
                                                                                                           msb.primary_uom_code,                --To UOM
                                                                                                           NULL,               --From UOM Name
                                                                                                           NULL                 -- To UOM Name
                                                                                                          ) primary_quantity,
                                                             rt.organization_id,
                                                             rsl.to_subinventory subinventory,
                                                             rsl.comments,
                                                             (SELECT MAX(attribute14) FROM rcv_shipment_lines WHERE shipment_header_id = cur_receipt.shipment_header_id) - 1 AS suffix,     --add suffix by Alfonso 10-DEC-2015
                                                             rt.ATTRIBUTE8,--erwin 20211209
                                                             rt.ATTRIBUTE9 --erwin 20211209
                                                        FROM rcv_shipment_lines   rsl,
                                                             mtl_system_items_b   msb,
                                                             rcv_transactions rt
                                                       WHERE rt.transaction_type = 'DELIVER'
                                                         AND EXISTS
                                                             (
                                                              SELECT 1
                                                                FROM mtl_parameters mp
                                                               WHERE EXISTS
                                                                     (
                                                                      SELECT 1
                                                                        FROM fnd_flex_values ffv
                                                                       WHERE EXISTS
                                                                             (
                                                                              SELECT 1
                                                                                FROM fnd_flex_value_sets ffvs
                                                                               WHERE ffvs.flex_value_set_name = 'XRSPI_PO_FILTER_IO_RCV'
                                                                                 AND ffv.flex_value_set_id = ffvs.flex_value_set_id
                                                                             )
                                                                         AND mp.organization_code = ffv.flex_value
                                                                     )
                                                                 AND msb.organization_id = mp.organization_id
                                                             )
                                                         AND rsl.shipment_header_id = cur_receipt.shipment_header_id
                                                         AND rsl.item_id = msb.inventory_item_id
                                                         AND msb.organization_id = rt.organization_id
                                                         AND cur_receipt.shipment_header_id = rt.shipment_header_id
                                                         AND rsl.shipment_line_id = rt.shipment_line_id
                                                         AND rsl.attribute15 IS NULL
                                                         AND rt.ATTRIBUTE9 IS NOT NULL) A,    -- add by Alfonso 10-DEC2-015
                                                     (SELECT mtln.product_transaction_id,
                                                             mtln.inventory_item_id,
                                                             mln.expiration_date,
                                                             mtln.primary_quantity,
                                                             mtln.lot_number,
                                                             mtln.organization_id
                                                        FROM mtl_transaction_lot_numbers mtln, mtl_lot_numbers mln
                                                       WHERE mtln.inventory_item_id = mln.inventory_item_id
                                                         AND mtln.lot_number = mln.lot_number) b
                                               WHERE A.transaction_id = b.product_transaction_id(+)
                                                 AND A.item_id = b.inventory_item_id(+)
                                                 AND A.segment1 NOT LIKE '03%'      -- excelude item consignment -- remarked 24JULI2015
                                                 AND A.organization_id = b.organization_id(+))) LOOP

                IF cur_receipt_lines.rn = 1 THEN

                  --Open File
                  IF NOT g_rec_status.b_error THEN

                  v_seqnum := lpad(APPS.XRSPI_RCP_RTN_SEQUENCE.NEXTVAL, 4, '0');--erwin add 20231215
                  --g_filename := c_receive_prefix || to_char(SYSDATE, 'YYYYMMDDHH24MISS') || '.txt';
                    g_filename := c_receive_prefix || to_char(SYSDATE, 'YYYYMMDDHH24MISS') || v_seqnum ||'.txt';--erwin add 20231215
                    IF NOT f_open_file('RECEIPT',
                                       g_filename,
                                       g_error_message) THEN
                      g_rec_status.b_error := TRUE;
                    END IF;
                  END IF;

                  utl_file.put_line(l_file, cur_receipt_lines.ctr);

                END IF;

                utl_file.put_line(l_file, cur_receipt_lines.data_receipt);

                -- update Attribute15
                    IF NOT f_upd_rcv_shipment_lines(cur_receipt_lines.l_rowid,
                                                    g_error_message) THEN

                      g_rec_status.b_error := TRUE;
                      IF g_rec_status.b_debug THEN
                        dbms_output.put_line(g_error_message);
                      END IF;

                    END IF;

                 --update Attribute14   -- Add by Alfonso - 10-DEC-2015
                    IF NOT f_upd_rcv_shipment_lines_att14(cur_receipt_lines.l_rowid,
                                                                               cur_receipt.shipment_header_id,
                                                    g_error_message) THEN

                      g_rec_status.b_error := TRUE;
                      IF g_rec_status.b_debug THEN
                        dbms_output.put_line(g_error_message);
                      END IF;

                    END IF;


              END LOOP;

            --Close File
            IF utl_file.is_open(l_file) THEN
              utl_file.fclose(l_file);
              utl_file.fcopy('EXPORT_DIR_RECEIPT_ARCH', g_filename, 'EXPORT_DIR_RECEIPT', g_filename);
              dbms_lock.sleep(1);
            END IF;

          END LOOP;

        END IF;

        IF NOT g_rec_status.b_error THEN
          COMMIT;
        ELSE
          ROLLBACK;
        END IF;

      END;
    */

  FUNCTION f_open_file (l_type          IN  VARCHAR2,
                        l_filename      IN  VARCHAR2,
                        l_error_message OUT VARCHAR2) RETURN BOOLEAN IS
  BEGIN

    l_file := utl_file.fopen (CASE
                                WHEN l_type = 'RECEIPT' THEN 'EXPORT_DIR_RECEIPT_ARCH'
                                WHEN l_type = 'RETURN'  THEN 'EXPORT_DIR_RETURN_ARCH'
                              END,
                              l_filename,
                              'W',
                              32767);

    RETURN TRUE;

  EXCEPTION
    WHEN utl_file.invalid_path THEN
      l_error_message := 'f_open_file: Invalid path';
      RETURN FALSE;
    WHEN OTHERS THEN
      l_error_message := 'f_open_file: ' || SQLERRM;
      RETURN FALSE;
  END f_open_file;

    PROCEDURE sp_create_receive (p_trx_header_id IN NUMBER) IS

    c_receive_prefix CONSTANT VARCHAR2(13) := 'Good_Receive_';
    c_dir_arch       CONSTANT VARCHAR2(30) := 'EXPORT_DIR_RECEIPT_ARCH';   -- arsip
    c_dir_out        CONSTANT VARCHAR2(30) := 'EXPORT_DIR_RECEIPT';        -- diambil TrakCare
    v_seqnum         VARCHAR2(4);
    g_error_message  VARCHAR2(4000);
    g_filename       VARCHAR2(35);
    g_tmp_filename   VARCHAR2(40);

  BEGIN

    FOR cur_receipt IN (SELECT h.trx_header_id,
                               h.receipt_number receipt_num,
                               h.receipt_date,
                               h.packing_slip,
                               h.organization_id
                          FROM xnrspi_rcv_hdr_receipt_return h
                         WHERE h.trx_header_id    = p_trx_header_id
                           AND h.transaction_type = 'RECEIVE'
                           AND h.status           = 'SUCCEEDED'
                           AND h.export_date      IS NULL
                           AND EXISTS (SELECT 1
                                         FROM fus_inv_org f
                                        WHERE f.organization_id = h.organization_id
                                          AND UPPER (f.organization_code) LIKE '%FAR')) LOOP

      g_filename     := NULL;
      g_tmp_filename := NULL;

      --Generate Good Receive
      FOR cur_receipt_lines IN (SELECT l_rowid,
                                       COUNT (1) OVER (PARTITION BY 1) ctr,
                                       ROW_NUMBER () OVER (PARTITION BY 1 ORDER BY 1) rn,
                                       delivery_order_no || '^' ||
                                       vendor_code || '^' ||
                                       vendor_name || '^' ||
                                       receipt_date || '^' ||
                                       docket_number || '^' ||
                                       docket_date || '^' ||
                                       currency || '^' ||
                                       exchange_rate || '^' ||
                                       completed || '^' ||
                                       export_time || '^' ||
                                       transaction_user || '^' ||
                                       item_code || '^' ||
                                       item_description || '^' ||
                                       RTRIM (TO_CHAR (NVL (item_quantity, quantity), 'FM999999990D999999',
                                                       'NLS_NUMERIC_CHARACTERS=''.,'''), '.') || '^' ||
                                       batch_no2 || '^' ||
                                       expiration_date2 || '^' ||
                                       uom_description || '^' ||
                                       receive_type || '^' ||
                                       location_code || '^' ||
                                       unit_cost || '^' ||
                                       remarks data_receipt
                                  FROM (SELECT A.l_rowid,
                                               A.shipment_line_id,
                                               '000INT' vendor_code,
                                               'Interface Oracle' vendor_name,
                                               TO_CHAR (A.transaction_date, 'DD/MM/YYYY') docket_date,
                                               (SELECT REGEXP_REPLACE (UPPER (fus.organization_code), 'FAR$', '')
                                                  FROM fus_inv_org fus
                                                 WHERE UPPER (fus.organization_code) LIKE '%FAR'
                                                   AND fus.organization_id = A.organization_id)
                                                 || A.receipt_num || A.suffix docket_number,
                                               'Rupiah' currency,
                                               '1' exchange_rate,
                                               'Y' completed,
                                               'Interface Oracle' transaction_user,
                                               A.segment1 item_code,
                                               A.description item_description,
                                               NULL item_quantity,
                                               NULL batch_no,
                                               NULL expiration_date,
                                               TO_CHAR (TO_DATE (A.attribute10, 'YYYY/MM/DD HH24:MI:SS'), 'DD/MM/YYYY') expiration_date2,
                                               A.attribute11 batch_no2,
                                               CASE
                                                 WHEN A.transaction_type = 'RETURN TO VENDOR' THEN A.primary_quantity * -1
                                                 ELSE A.primary_quantity
                                               END quantity,
                                               'Stock UOM' uom_description,
                                               A.subinventory location_code,
                                               NULL remarks,
                                               '0' unit_cost,
                                               'NOR' receive_type,
                                               TO_CHAR (SYSDATE, 'DD/MM/YYYY') export_time,
                                               REPLACE (REPLACE (REPLACE (cur_receipt.packing_slip, '^', ' '),
                                                                 CHR (13), ' '),
                                                        CHR (10), ' ') delivery_order_no,
                                               TO_CHAR (cur_receipt.receipt_date, 'DD/MM/YYYY') receipt_date
                                          FROM (SELECT l.ROWID                     l_rowid,
                                                       l.shipment_line_id,
                                                       cur_receipt.receipt_date    transaction_date,
                                                       cur_receipt.receipt_num     receipt_num,
                                                       l.item_number               segment1,
                                                       l.item_description          description,
                                                       'DELIVER'                   transaction_type,
                                                       l.uom_code                  primary_unit_of_measure,
                                                       l.trx_line_id               transaction_id,
                                                       l.inventory_item_id         item_id,
                                                       NVL (t.qty, l.qty)          primary_quantity,
                                                       cur_receipt.organization_id organization_id,
                                                       l.subinventory              subinventory,
                                                       NULL                        comments,
                                                       (SELECT CASE WHEN COUNT (1) > 0 THEN COUNT (1) * -1 END
                                                          FROM xnrspi_rcv_hdr_receipt_return h2
                                                         WHERE h2.organization_id = cur_receipt.organization_id
                                                           AND h2.receipt_number  = cur_receipt.receipt_num
                                                           AND h2.export_date     IS NOT NULL
                                                           AND h2.trx_header_id  <> cur_receipt.trx_header_id) suffix,
                                                       TO_CHAR (t.expiration_date, 'YYYY/MM/DD HH24:MI:SS') attribute10,
                                                       t.lot_number                attribute11
                                                  FROM xnrspi_rcv_lines_receipt_return l,
                                                       xnrspi_rcv_lots_receipt_return  t
                                                 WHERE l.trx_header_id  = cur_receipt.trx_header_id
                                                   AND t.trx_line_id(+) = l.trx_line_id
                                                   AND NVL (l.asset_tracked_flag, 'N') = 'N'
                                                   AND NVL (t.qty, l.qty) > 0) A
                                         WHERE A.segment1 NOT LIKE '03%')) LOOP   -- exclude item consignment

        IF cur_receipt_lines.rn = 1 THEN

          --Open File
          v_seqnum   := LPAD (xrspi_rcp_rtn_seq.NEXTVAL, 4, '0');
          g_filename     := c_receive_prefix || TO_CHAR (SYSDATE, 'YYYYMMDDHH24MISS') || v_seqnum || '.txt';
          g_tmp_filename := g_filename || '.tmp';   -- ditulis sebagai .tmp dulu

          IF NOT f_open_file ('RECEIPT', g_tmp_filename, g_error_message) THEN
            raise_application_error (-20001, g_error_message);
          END IF;

          utl_file.put_line (l_file, cur_receipt_lines.ctr);

        END IF;

        utl_file.put_line (l_file, cur_receipt_lines.data_receipt);

      END LOOP;

      --Close File, rename .tmp -> .txt, tandai header
      IF utl_file.is_open (l_file) THEN

        utl_file.fclose (l_file);

        -- 1. File lengkap di folder arsip: .tmp -> .txt
        utl_file.frename (c_dir_arch, g_tmp_filename, c_dir_arch, g_filename, FALSE);

        -- 2. Copy ke folder TrakCare sebagai .tmp, lalu rename ke .txt
        --    supaya TrakCare tidak mengambil file yang belum selesai di-copy
        utl_file.fcopy   (c_dir_arch, g_filename, c_dir_out, g_tmp_filename);
        utl_file.frename (c_dir_out, g_tmp_filename, c_dir_out, g_filename, FALSE);

        UPDATE xnrspi_rcv_hdr_receipt_return
           SET export_file_name = g_filename,
               export_date      = SYSDATE,
               export_message   = NULL
         WHERE trx_header_id    = cur_receipt.trx_header_id;

      ELSE

        -- Tidak ada line yang dikirim (semua consignment / asset / qty 0)
        UPDATE xnrspi_rcv_hdr_receipt_return
           SET export_message = 'Tidak ada line yang dikirim ke TrakCare'
         WHERE trx_header_id  = cur_receipt.trx_header_id;

      END IF;

    END LOOP;

    COMMIT;

  EXCEPTION
    WHEN OTHERS THEN
      g_error_message := SUBSTR (SQLERRM || ' | ' || dbms_utility.format_error_backtrace, 1, 4000);

      IF utl_file.is_open (l_file) THEN
        utl_file.fclose (l_file);
      END IF;

      -- Hapus file setengah jadi (arsip & outbound) supaya bersih saat diproses ulang
      IF g_tmp_filename IS NOT NULL THEN
        BEGIN utl_file.fremove (c_dir_arch, g_tmp_filename); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN utl_file.fremove (c_dir_arch, g_filename);     EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN utl_file.fremove (c_dir_out,  g_tmp_filename); EXCEPTION WHEN OTHERS THEN NULL; END;
      END IF;

      ROLLBACK;

      -- export_date tetap NULL supaya bisa diproses ulang
      UPDATE xnrspi_rcv_hdr_receipt_return
         SET export_message = g_error_message
       WHERE trx_header_id  = p_trx_header_id;

      COMMIT;

  END sp_create_receive;
END;
/